# claude-agents#523: a delegated DECISION's `Resolves:` line is recognised wherever it sits in the body (CRLF-safe,
# blank lines ok, /pull vs /issues URL forms), by ONE shared helper `decision_resolves_id <body>` in
# hooks/pipeline-markers.sh that supervisor.sh's infra_staging_only (and the orchestrator doc) use.
# Contract tested: helper prints the numeric issuecomment id and exits 0 when exactly one distinct, unquoted `Resolves:`
# target exists; otherwise prints nothing and exits non-zero. Expected values are hand-written below.
DR_ROOT=$(cd "$HERE/../../.." && pwd)
. "$DR_ROOT/hooks/pipeline-markers.sh"

DR_ID=6467612327
DR_URL="https://github.com/owner/project-a/issues/1599#issuecomment-$DR_ID"
DR_PULL="https://github.com/owner/project-a/pull/1601#issuecomment-$DR_ID"
DR_OTHER="https://github.com/owner/project-a/issues/1599#issuecomment-999"

# The rejected #1599 body (repo name replaced by a placeholder; Resolves: is the last line, line 2 blank).
DR_INCIDENT='**[delivery-lead] DECISION**

Fast-lane tickets (#1599 has no `TESTS WRITTEN` marker) skip the pre-implementation `TESTS APPROVED` gate by design — there is no test-writer stage to approve. The equivalent gate here is the post-implementation `[test-reviewer] PASS` on PR #1601: https://github.com/owner/project-a/pull/1601#issuecomment-6467564264

Deployer: proceed on that PASS. No separate `TESTS APPROVED` comment will exist for fast-lane work.

Resolves: '"$DR_URL"

dr_run() {  # dr_run <body> → sets DR_OUT, DR_RC
  DR_OUT=$(decision_resolves_id "$1" 2>/dev/null); DR_RC=$?
}
dr_expect_id() { dr_run "$1"; assert_eq "$DR_OUT" "$2" "$3 id" && assert_exit0 "$DR_RC" "$3 exit"; }
dr_expect_none() {
  dr_run "$1"
  assert_eq "$DR_OUT" "" "$2 prints nothing" || return 1
  [ "$DR_RC" -ne 0 ] || { fail "$2: expected non-zero exit"; return 1; }
  # a stub that merely throws NotImplemented must not count as a rejection
  case "$(decision_resolves_id "$1" 2>&1 >/dev/null)" in *NotImplemented*) fail "$2: helper not implemented"; return 1;; esac
}

t_dr_ac1_last_line_after_prose() { dr_expect_id "$DR_INCIDENT" "$DR_ID" "AC1"; }
t_dr_ac2_line2() { dr_expect_id "**[delivery-lead] DECISION**
Resolves: $DR_URL

Some prose." "$DR_ID" "AC2"; }
t_dr_ac3_crlf() { dr_expect_id "$(printf '**[delivery-lead] DECISION**\r\nResolves: %s\r\n\r\nprose\r\n' "$DR_URL")" "$DR_ID" "AC3"; }
t_dr_ac3_crlf_last_line_no_trailing_newline() { dr_expect_id "$(printf '**[delivery-lead] DECISION**\r\n\r\nprose\r\nResolves: %s\r' "$DR_URL")" "$DR_ID" "AC3b"; }
t_dr_ac4_blank_line() { dr_expect_id "**[delivery-lead] DECISION**

Resolves: $DR_URL" "$DR_ID" "AC4"; }
t_dr_ac5_pull_and_issues_forms_match() {
  local a b
  a=$(decision_resolves_id "**[delivery-lead] DECISION**
Resolves: $DR_PULL" 2>/dev/null); b=$(decision_resolves_id "**[delivery-lead] DECISION**
Resolves: $DR_URL" 2>/dev/null)
  assert_eq "$a" "$DR_ID" "AC5 pull form id" && assert_eq "$b" "$DR_ID" "AC5 issues form id"
}
t_dr_ac5_same_target_twice_in_two_forms_is_one_target() {
  dr_expect_id "**[delivery-lead] DECISION**
Resolves: $DR_PULL
Resolves: $DR_URL" "$DR_ID" "AC5b"; }
t_dr_ac6_two_different_targets() { dr_expect_none "**[delivery-lead] DECISION**
Resolves: $DR_URL
Resolves: $DR_OTHER" "AC6"; }
t_dr_ac7_quoted_only() { dr_expect_none "**[delivery-lead] DECISION**

> Resolves: $DR_URL

I disagree with the above." "AC7"; }
t_dr_ac7_quoted_ignored_but_unquoted_counts() { dr_expect_id "**[delivery-lead] DECISION**
> Resolves: $DR_OTHER
Resolves: $DR_URL" "$DR_ID" "AC7b"; }
t_dr_ac9_no_resolves() { dr_expect_none "**[delivery-lead] DECISION**

Proceed. See $DR_URL for context." "AC9"; }
t_dr_resolves_on_line1_is_not_a_decision_target() { dr_expect_none "Resolves: $DR_URL" "marker-less line 1"; }

# --- infra_staging_only (supervisor.sh) through a stubbed gh: AC8, AC10, AC11 ---
dr_infra() {  # dr_infra <decision-body> <blocked-url> → exit code of infra_staging_only; uses supervisor.sh's real function
  local d bin rc; d=$(mktemp -d "${TMPDIR:-/tmp}/dr523.XXXXXX"); bin=$d/bin; mkdir -p "$bin"
  jq -n --arg dec "$1" --arg url "$2" '{body:"Scope: staging-only\n",comments:[
    {url:$url,createdAt:"2026-10-28T12:00:00Z",body:"**[infra-planner] BLOCKED**\nBlocked on: dependency — waiting on a staging fixture\n"},
    {url:"https://example.invalid/plan",createdAt:"2026-10-28T11:00:00Z",body:"**[infra-planner] PLAN READY**\nstaging only\n"},
    {url:"https://example.invalid/dec",createdAt:"2026-10-28T13:06:39Z",body:$dec}]}' > "$d/issue.json"
  printf '#!/bin/bash\n[ "$1 $2" = "issue view" ] && { cat "%s/issue.json"; exit 0; }\nexit 1\n' "$d" > "$bin/gh"; chmod +x "$bin/gh"
  ( PATH="$bin:$PATH"; slog() { :; }
    eval "$(sed -n '/^infra_staging_only()/,/^}/p' "$DR_ROOT/skills/orchestrate/supervisor.sh")"
    infra_staging_only owner/project-a 1599 "$2" ); rc=$?
  rm -rf "$d"; return $rc
}
t_dr_ac8_wrong_target_still_fails() {
  dr_infra "**[delivery-lead] DECISION**

prose

Resolves: $DR_OTHER" "$DR_URL" && { fail "AC8: decision naming a different comment resumed"; return 1; }
  dr_infra "**[delivery-lead] DECISION**

prose

Resolves: $DR_URL" "$DR_URL" || { fail "AC8 control: correct target should resume"; return 1; }
}
t_dr_ac10_infra_verdict_matches_helper_on_every_fixture() {
  local name body helper want got
  while IFS='|' read -r name body; do
    body=$(printf '%b' "$body")
    helper=$(decision_resolves_id "$body" 2>/dev/null)
    want=1; [ "$helper" = "$DR_ID" ] && want=0
    dr_infra "$body" "$DR_URL"; got=$?
    [ "$want" = "$got" ] || { fail "AC10 $name: helper says rc=$want, infra_staging_only rc=$got"; return 1; }
    case "$name" in good*) [ "$got" = 0 ] || { fail "AC10 $name should resume"; return 1; };; *) [ "$got" != 0 ] || { fail "AC10 $name should not resume"; return 1; };; esac
  done <<EOF2
good-line2|**[delivery-lead] DECISION**\nResolves: $DR_URL\nprose
good-last|**[delivery-lead] DECISION**\n\nprose\n\nResolves: $DR_URL
good-crlf|**[delivery-lead] DECISION**\r\n\r\nResolves: $DR_URL\r\n
good-pullform|**[delivery-lead] DECISION**\n\nResolves: $DR_PULL
bad-two|**[delivery-lead] DECISION**\nResolves: $DR_URL\nResolves: $DR_OTHER
bad-quoted|**[delivery-lead] DECISION**\n> Resolves: $DR_URL
bad-none|**[delivery-lead] DECISION**\nprose only
bad-wrong|**[delivery-lead] DECISION**\n\nResolves: $DR_OTHER
EOF2
}
t_dr_ac10_infra_staging_only_uses_shared_helper() {
  local f="$DR_ROOT/skills/orchestrate/supervisor.sh" fn
  fn=$(sed -n '/^infra_staging_only()/,/^}/p' "$f")
  assert_contains "$fn" "decision_resolves_id" "AC10 supervisor calls helper" || return 1
  assert_not_contains "$fn" 'l2 == ' "AC10 supervisor no positional l2 check" || return 1
  assert_not_contains "$fn" 'split("\n")[1]' "AC10 supervisor no line-2 extraction"
}
t_dr_ac10_orchestrator_doc_uses_shared_helper() {
  local doc; doc=$(cat "$DR_ROOT/agents/orchestrator.md")
  assert_contains "$doc" "decision_resolves_id" "AC10 orchestrator names helper" || return 1
  if grep -F 'DECISION|JP CONFIRMED' "$DR_ROOT/agents/orchestrator.md" | grep -qF 'split("\n")[1]'; then
    fail "AC10: orchestrator.md decision extraction still uses split(\"\\n\")[1]"; return 1; fi
  if grep -qiE 'Resolves:`? line \(line 2\)|line 2 is `?Resolves|line 2 `?Resolves' "$DR_ROOT/agents/orchestrator.md"; then
    fail "AC10: orchestrator.md prose still says Resolves is line 2"; return 1; fi
}
t_dr_ac11_incident_replay_resumes() {
  dr_infra "$DR_INCIDENT" "$DR_URL" || { fail "AC11: #1599 incident body (Resolves last) did not resume"; return 1; }
}

# --- Observability: ambiguous/malformed Resolves: is logged via slog with release SHA, host, route ---
t_dr_obs_ambiguous_logs_slog() {
  local log sha host
  log=$( slog() { printf '%s\n' "$*"; }
    decision_resolves_id "**[delivery-lead] DECISION**
Resolves: $DR_URL
Resolves: $DR_OTHER" 2>/dev/null )
  sha=$(git -C "$DR_ROOT" rev-parse --short=7 HEAD); host=$(hostname -s)
  assert_contains "$log" "orchestrator-decision" "obs route" || return 1
  assert_contains "$log" "$sha" "obs release sha" || return 1
  assert_contains "$log" "$host" "obs host" || return 1
  assert_contains "$log" "$DR_ID" "obs names first comment id" || return 1
  assert_contains "$log" "999" "obs names second comment id" || return 1
}
t_dr_obs_log_has_no_body_text() {
  local log
  log=$( slog() { printf '%s\n' "$*"; }
    decision_resolves_id "**[delivery-lead] DECISION**
SECRET-PROSE-TOKEN
Resolves: $DR_URL
Resolves: $DR_OTHER" 2>/dev/null )
  assert_contains "$log" "orchestrator-decision" "obs logged" || return 1
  assert_not_contains "$log" "SECRET-PROSE-TOKEN" "obs no body text"
}

for t in t_dr_ac1_last_line_after_prose t_dr_ac2_line2 t_dr_ac3_crlf t_dr_ac3_crlf_last_line_no_trailing_newline \
  t_dr_ac4_blank_line t_dr_ac5_pull_and_issues_forms_match t_dr_ac5_same_target_twice_in_two_forms_is_one_target \
  t_dr_ac6_two_different_targets t_dr_ac7_quoted_only t_dr_ac7_quoted_ignored_but_unquoted_counts t_dr_ac9_no_resolves \
  t_dr_resolves_on_line1_is_not_a_decision_target t_dr_ac8_wrong_target_still_fails \
  t_dr_ac10_infra_verdict_matches_helper_on_every_fixture t_dr_ac10_infra_staging_only_uses_shared_helper \
  t_dr_ac10_orchestrator_doc_uses_shared_helper t_dr_ac11_incident_replay_resumes \
  t_dr_obs_ambiguous_logs_slog t_dr_obs_log_has_no_body_text; do run_test "$t"; done
