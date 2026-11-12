# Issue #676 (a) — scan-backlog.sh never proposes a ticket the pipeline already touched. The claim search it relied on is
# eventually consistent and capped, so a search that succeeds with an incomplete list relabelled in-flight and shipped
# tickets `agent-proposed` (43 on 2026-11-06). Now: `user-feedback` is excluded by the label filter, and every candidate
# that passed the filter gets one comments read; a routing marker of any agent or a `[supervisor] NOTE claim:` line means
# "never propose" (neither agent-proposed nor the goal agent-go), and a failed or unparsable read skips the ticket for
# this scan (fail closed, one tagged stderr line each, one Slack alert per scan).
#
# gh stub (fixture files in the sandbox HOME; expected values are hand-written from the ticket):
#   issues.json          the open issues; the plain `issue list` call runs the caller's own --jq over it (the real filter)
#   claimed.txt          stdout of the claim search (default: empty, exit 0 — the 2026-11-06 failure shape)
#   claim-search-fail    when present, the claim search exits 1
#   comments-<n>.json    the per-issue comments read (REST shape; default [])
#   comments-<n>.raw     raw stdout of that read instead (the unparsable case)
#   comments-<n>.rc      exit code of that read (default 0)
#   reg-open.json        the goal registry's open issues (default [])
# Placeholder repo names only.

HERE_SIG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

sig_home() {
  local home; home=$(new_home); SIG_HOME=$home; mkdir -p "$home/bin"
  echo '[]' > "$home/issues.json"; echo '[]' > "$home/reg-open.json"; : > "$home/gh.log"; : > "$home/curl.log"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh.log"
if [ "$1" = api ]; then
  case "$2" in
    repos/*/issues/[0-9]*/comments*)
      n=$(printf '%s' "$2" | sed -E 's#.*/issues/([0-9]+)/comments.*#\1#')
      rc=$(cat "$HOME/comments-$n.rc" 2>/dev/null || echo 0)
      [ "$rc" -eq 0 ] || { echo "gh: HTTP 502" >&2; exit "$rc"; }
      if [ -f "$HOME/comments-$n.raw" ]; then cat "$HOME/comments-$n.raw"
      elif [ -f "$HOME/comments-$n.json" ]; then cat "$HOME/comments-$n.json"
      else echo '[]'; fi
      exit 0 ;;
  esac
  case "$*" in
    *"-X PATCH"*) cat >/dev/null; echo '{}' ;;   # the goal grant ledger write
    *state=open*) cat "$HOME/reg-open.json" ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
if [ "$1" = issue ] && [ "$2" = list ]; then
  case "$*" in *--search*) [ -f "$HOME/claim-search-fail" ] && exit 1; cat "$HOME/claimed.txt" 2>/dev/null; exit 0 ;; esac
  expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  jq -r "$expr" "$HOME/issues.json"
fi
exit 0
STUB
  cat > "$home/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$HOME/curl.log"; echo ok
STUB
  chmod +x "$home/bin/gh" "$home/bin/curl"
  printf 'SCAN_BACKLOG=1\nSLACK_WEBHOOK_URL=https://example.invalid/hook\nDISPATCH_REPOS=("project-a/repo-a:/tmp/a")\nGOAL_REGISTRY_REPO=example-owner/registry\n' \
    > "$home/.claude/pipeline/config.local.sh"
}
# sig_issue <n> <title> [label...]
sig_issue() {
  local n=$1 t=$2; shift 2
  jq --argjson n "$n" --arg t "$t" --argjson l "$(printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -sc 'map({name:.})')" \
    '. + [{number:$n,title:$t,labels:$l}]' "$SIG_HOME/issues.json" > "$SIG_HOME/i.tmp" && mv "$SIG_HOME/i.tmp" "$SIG_HOME/issues.json"
}
# sig_comment <n> <body> — one more comment on issue n, REST shape
sig_comment() {
  local f="$SIG_HOME/comments-$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq --arg b "$2" '. + [{id: (length + 1), body: $b, created_at: "2026-11-06T00:00:00Z", user: {login: "someone"}}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
sig_scan() {  # one scan-backlog.sh run in the sandbox; stderr kept in $SIG_HOME/stderr.log
  HOME="$SIG_HOME" PATH="$SIG_HOME/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" /bin/bash "$HERE_SIG/../scan-backlog.sh" >"$SIG_HOME/stdout.log" 2>"$SIG_HOME/stderr.log"
}
sig_edits() { grep '^issue edit ' "$SIG_HOME/gh.log"; }
sig_edit_count() { sig_edits | grep -c "^issue edit $1 "; }
sig_cleanup() { rm -rf "$SIG_HOME"; }

# sig_goal_registry — one approved (go:true) label goal "goal: Alpha" on project-a/repo-a, in the registry fixture
sig_goal_registry() {
  local block
  block=$(jq -nc '{v:2,id:"g-alpha",title:"goal: Alpha",label:"goal: Alpha",repos:["project-a/repo-a"],order:1,go:true,granted:[],host:"",host_pref:"",spec:"label:goal: Alpha",instructions:""}')
  jq -nc --arg body "$(printf 'Goal: Alpha\n\n```json\n%s\n```\n' "$block")" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '[{number:107, title:"Goal", body:$body, state:"open", labels:[{name:"delivery-goal"}], created_at:$now, updated_at:$now, closed_at:null}]' > "$SIG_HOME/reg-open.json"
}

test_sig_positive_unlabelled_uncommented_issue_is_proposed() {
  sig_home; sig_issue 1 "brand new"
  sig_scan
  local edits reads; edits=$(sig_edits); reads=$(grep -c '^api repos/project-a/repo-a/issues/1/comments?per_page=100 --paginate' "$SIG_HOME/gh.log")
  sig_cleanup
  assert_eq "$(printf '%s\n' "$edits" | grep -c .)" "1" "positive: exactly one edit" || return 1
  assert_contains "$edits" "issue edit 1 --repo project-a/repo-a --add-label agent-proposed" "positive: the new issue gets agent-proposed (unchanged behaviour)" || return 1
  assert_eq "$reads" "1" "positive: one paginated comments read for the candidate" || return 1
}

test_sig_non_marker_comments_do_not_block_a_proposal() {
  # the guard is "a routing marker or a claim", not "any comment": discussion, a NOTE and an off-vocabulary line are inert
  sig_home; sig_issue 1 "discussed, never started"
  sig_comment 1 "Could we also cover the mobile view?"
  sig_comment 1 "**[fullstack-developer] NOTE** looked at this, nothing started"
  sig_comment 1 "**[deployer] COMPLETED**"
  sig_comment 1 "**[supervisor] NOTE** auto-retry 1/3: ci_red cleared"
  sig_scan
  local n; n=$(sig_edit_count 1); sig_cleanup
  assert_eq "$n" "1" "control: comments that are not routing markers or claims leave the issue proposable" || return 1
}

test_sig_negative_i_user_feedback_label_is_never_proposed() {
  sig_home; sig_issue 2 "feedback bug" user-feedback; sig_issue 1 "control"
  sig_scan
  local n ctrl reads; n=$(sig_edit_count 2); ctrl=$(sig_edit_count 1); reads=$(grep -c '^api repos/project-a/repo-a/issues/2/comments' "$SIG_HOME/gh.log")
  sig_cleanup
  assert_eq "$ctrl" "1" "(i) control: the unlabelled issue is proposed" || return 1
  assert_eq "$n" "0" "(i) an issue labelled user-feedback is never labelled by the scan" || return 1
  assert_eq "$reads" "0" "(i) the label filter drops it before any comments read (per-candidate read only)" || return 1
}

test_sig_negative_ii_routing_marker_comment_blocks_the_proposal() {
  sig_home; sig_issue 3 "shipped to staging"; sig_issue 1 "control"
  sig_comment 3 "**[deployer] DEPLOYED TO STAGING**"
  sig_scan
  local n ctrl out; n=$(sig_edit_count 3); ctrl=$(sig_edit_count 1); out=$(cat "$SIG_HOME/stdout.log")
  sig_cleanup
  assert_eq "$ctrl" "1" "(ii) control: the unlabelled issue is proposed" || return 1
  assert_eq "$n" "0" "(ii) an issue with a [deployer] DEPLOYED TO STAGING comment is never labelled" || return 1
  assert_not_contains "$out" "repo-a#3" "(ii) it is not listed in the digest of new issues either" || return 1
}

test_sig_negative_ii_any_agent_marker_blocks() {
  # marker_re with no argument: every agent's vocabulary, each on its own issue
  sig_home
  sig_issue 31 "pm ready";      sig_comment 31 "**[product-manager] READY FOR ENGINEERING**"
  sig_issue 32 "implemented";   sig_comment 32 "**[fullstack-developer] IMPLEMENTED**"
  sig_issue 33 "blocked";       sig_comment 33 "$(printf '**[code-reviewer] BLOCKED**\nBlocked on: other — x')"
  sig_issue 34 "triaged";       sig_comment 34 "Looks fine to me"; sig_comment 34 "**[intake] TRIAGED BUG**"
  sig_issue 35 "applied";       sig_comment 35 "**[infra-operator] APPLIED**: done"
  sig_scan
  local total; total=$(sig_edits | grep -c .); sig_cleanup
  assert_eq "$total" "0" "(ii) a routing marker of any agent, anywhere in the thread, blocks the proposal" || return 1
}

test_sig_negative_iii_claim_comment_blocks_when_the_claim_search_missed_it() {
  # the 2026-11-06 failure: the claim search exits 0 with an empty list, the issue itself carries the claim
  sig_home; sig_issue 4 "in flight"; sig_issue 1 "control"
  : > "$SIG_HOME/claimed.txt"
  sig_comment 4 "**[supervisor] NOTE** claim: Claude 2026-11-06T00:00:00Z"
  sig_scan
  local n ctrl search; n=$(sig_edit_count 4); ctrl=$(sig_edit_count 1); search=$(grep -c -- '--search' "$SIG_HOME/gh.log")
  sig_cleanup
  assert_eq "$search" "1" "(iii) the claim search still runs as the cheap pre-filter" || return 1
  assert_eq "$ctrl" "1" "(iii) control: the unlabelled issue is proposed" || return 1
  assert_eq "$n" "0" "(iii) a claimed issue the search missed is never labelled" || return 1
}

test_sig_negative_iv_failed_comments_read_fails_closed_and_alerts_once() {
  sig_home; sig_issue 5 "unreadable"; sig_issue 6 "unreadable too"; sig_issue 1 "control"
  echo 1 > "$SIG_HOME/comments-5.rc"; echo 1 > "$SIG_HOME/comments-6.rc"
  sig_scan
  local n5 n6 ctrl err curl out sha
  n5=$(sig_edit_count 5); n6=$(sig_edit_count 6); ctrl=$(sig_edit_count 1)
  err=$(cat "$SIG_HOME/stderr.log"); curl=$(grep 'comments read failed' "$SIG_HOME/curl.log"); out=$(cat "$SIG_HOME/stdout.log")
  sha=$(git -C "$HERE_SIG" rev-parse HEAD 2>/dev/null || echo unknown)
  sig_cleanup
  assert_eq "$n5" "0" "(iv) no label write for an issue whose comments read failed" || return 1
  assert_eq "$n6" "0" "(iv) nor for the second one" || return 1
  assert_eq "$ctrl" "1" "(iv) control: a readable issue of the same scan is still proposed" || return 1
  assert_not_contains "$out" "repo-a#5" "(iv) the skipped issue is not in the digest of new issues" || return 1
  assert_eq "$(printf '%s\n' "$err" | grep -c 'comments read failed for project-a/repo-a#')" "2" "(iv) one stderr line per skipped issue" || return 1
  assert_contains "$err" "comments read failed for project-a/repo-a#5" "(iv) the stderr line names the repo and issue" || return 1
  assert_contains "$err" "release=$sha environment=$(hostname -s) route=scan-backlog" "(iv) tagged: release = commit SHA, environment = host, route" || return 1
  assert_eq "$(printf '%s\n' "$curl" | grep -c .)" "1" "(iv) ONE Slack message per scan, however many reads failed" || return 1
  assert_contains "$curl" "example.invalid/hook" "(iv) through the existing webhook" || return 1
  assert_contains "$curl" "comments read failed for 2 issue(s)" "(iv) the payload carries the count" || return 1
  assert_contains "$curl" "project-a/repo-a#5 project-a/repo-a#6" "(iv) and the refs" || return 1
  assert_contains "$curl" "release=$sha environment=$(hostname -s) route=scan-backlog" "(iv) the payload is tagged the same way" || return 1
  assert_not_contains "$curl" "unreadable" "(iv) the payload carries no issue text" || return 1
}

test_sig_unparsable_comments_read_fails_closed() {
  sig_home; sig_issue 7 "garbage"; sig_issue 8 "error object"; sig_issue 1 "control"
  echo 'not json at all' > "$SIG_HOME/comments-7.raw"
  echo '{"message":"Server Error"}' > "$SIG_HOME/comments-8.raw"
  sig_scan
  local n7 n8 ctrl err; n7=$(sig_edit_count 7); n8=$(sig_edit_count 8); ctrl=$(sig_edit_count 1); err=$(cat "$SIG_HOME/stderr.log")
  sig_cleanup
  assert_eq "$ctrl" "1" "unparsable: control still proposed" || return 1
  assert_eq "$n7" "0" "unparsable: non-JSON output skips the issue" || return 1
  assert_eq "$n8" "0" "unparsable: a JSON document that is not a comment list skips the issue" || return 1
  assert_contains "$err" "comments read failed for project-a/repo-a#7" "unparsable: reported like a failed read" || return 1
}

test_sig_goal_go_is_guarded_too() {
  # the approved-goal branch (agent-go instead of agent-proposed) sits behind the same guard
  sig_home; sig_goal_registry
  sig_issue 10 "goal ticket, fresh" "goal: Alpha"
  sig_issue 11 "goal ticket, shipped" "goal: Alpha"; sig_comment 11 "**[deployer] DEPLOYED**"
  sig_issue 12 "goal ticket, unreadable" "goal: Alpha"; echo 1 > "$SIG_HOME/comments-12.rc"
  sig_scan
  local e10 n11 n12; e10=$(sig_edits | grep '^issue edit 10 '); n11=$(sig_edit_count 11); n12=$(sig_edit_count 12)
  sig_cleanup
  assert_contains "$e10" "--add-label agent-go" "goal control: a fresh ticket of an approved goal gets agent-go" || return 1
  assert_eq "$n11" "0" "goal: a ticket with a routing marker gets neither agent-go nor agent-proposed" || return 1
  assert_eq "$n12" "0" "goal: an unreadable ticket gets neither" || return 1
}

test_sig_failed_claim_search_still_fails_closed_for_the_repo() {
  # Expected Behavior 3: the pre-filter's own fail-closed behaviour and alert are unchanged
  sig_home; sig_issue 1 "brand new"
  touch "$SIG_HOME/claim-search-fail"
  sig_scan
  local n reads curl; n=$(sig_edits | grep -c .); reads=$(grep -c '/comments' "$SIG_HOME/gh.log"); curl=$(cat "$SIG_HOME/curl.log")
  sig_cleanup
  assert_eq "$n" "0" "claim search failed: nothing is labelled" || return 1
  assert_eq "$reads" "0" "claim search failed: the repo is skipped before any per-issue read" || return 1
  assert_contains "$curl" "claim search failed for project-a/repo-a" "claim search failed: the existing alert is posted" || return 1
}

echo "-- scan-backlog in-flight guard (#676)"
run_test test_sig_positive_unlabelled_uncommented_issue_is_proposed
run_test test_sig_non_marker_comments_do_not_block_a_proposal
run_test test_sig_negative_i_user_feedback_label_is_never_proposed
run_test test_sig_negative_ii_routing_marker_comment_blocks_the_proposal
run_test test_sig_negative_ii_any_agent_marker_blocks
run_test test_sig_negative_iii_claim_comment_blocks_when_the_claim_search_missed_it
run_test test_sig_negative_iv_failed_comments_read_fails_closed_and_alerts_once
run_test test_sig_unparsable_comments_read_fails_closed
run_test test_sig_goal_go_is_guarded_too
run_test test_sig_failed_claim_search_still_fails_closed_for_the_repo
