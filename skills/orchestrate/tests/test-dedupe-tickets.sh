# JP, 2026-10-31: every ticket request is checked for a pre-existing ticket BEFORE it is created.
# Incident: scheduler #2016 (merge note and report at checkout) was filed and only later rejected as a
# duplicate of #1840 (checkout notes optional, shared with report) / #1841 (one shared checkout note
# field). Covers skills/orchestrate/find-duplicates.sh (the shared search) and
# hooks/dedupe-ticket-guard.sh (the PreToolUse block on every ticket-creating command), offline,
# against a fake `gh` that serves fixture search results built from the real tickets.

HERE_DUP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DUP=$(cd "$HERE_DUP/../../.." && pwd)
FIND_DUP="$ROOT_DUP/skills/orchestrate/find-duplicates.sh"
HOOK_DUP="$ROOT_DUP/hooks/dedupe-ticket-guard.sh"

T2016_TITLE="Merge Note and Report into one field at tech app checkout"
T2016_BODY='## Why
Technicians type the same visit information twice at checkout (the visit report, then the "Your notes on this visit" box); entering it once saves time at every checkout.
Keep both records but pre-fill the Quick Log "Your notes on this visit" box from the report the technician just sent. `visits.completed_notes` feeds visit history; `QuickLogHoursSheet.tsx` renders the box.'

dup_setup() {  # fresh fake gh + fixture dir; sets DUP_DIR, PATH
  DUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-dup.XXXXXX")
  mkdir -p "$DUP_DIR/bin" "$DUP_DIR/cache"
  python3 - "$DUP_DIR/search.json" <<'PY'
import json, sys
R = "https://api.github.com/repos/Benjis-Plants/benjis-ops-tool"
def it(n, title, body, labels, state="open", pr=False, reason=None):
    return {"number": n, "title": title, "state": state, "state_reason": reason, "pr": pr, "labels": labels,
            "html_url": "https://github.com/Benjis-Plants/benjis-ops-tool/%s/%d" % ("pull" if pr else "issues", n),
            "repository_url": R, "body": body}
items = [
  it(1840, "Unify checkout notes with the visit report notes field; notes no longer required at checkout",
     "Why: Technicians retype the same note twice at check-out; one optional shared field saves time. For technician users the check-out note IS visit_reports.notes; `visits.completed_notes` is no longer written for them.",
     ["agent-in-progress", "user-feedback"]),
  it(1841, "Tech app: check-out note field shared with Visit report notes, optional (UI)",
     "Why: At check-out the technician should type the note once, in one field that is also the first box of the Visit report. Parent: Benjis-Plants/scheduler#1840. `QuickLogHoursSheet.tsx`, `src/components/tech/checkoutReportGate.ts`.",
     ["agent-in-progress", "user-feedback"]),
  it(1853, "feat(#1840): unify check-out note with visit report notes (server + readers)", "Closes #1840", [], pr=True),
  it(2045, "Fix checkout blocked by \"invalid photo\" error in tech app", "Technician cannot check out: the photo upload fails with invalid photo.", ["bug", "user-feedback"]),
  it(2046, "Fix tech app stuck in landscape orientation", "The tech app does not rotate back to portrait.", ["bug"], state="closed", reason="completed"),
  it(1757, "Add Finch group's second location to its customer note", "Customer note for Finch.", ["user-feedback"], state="closed", reason="not_planned"),
  it(1500, "Timesheet export to payroll CSV", "Export the weekly timesheet as CSV for payroll.", []),
]
json.dump(items, open(sys.argv[1], "w"))
PY
  cat > "$DUP_DIR/bin/gh" <<EOF
#!/bin/bash
# Fake gh for test-dedupe-tickets.sh: canonical repo names, fixture search results, failure switch.
printf '%s\n' "\$*" >> "$DUP_DIR/gh.log"
[ -e "$DUP_DIR/fail" ] && { echo "API rate limit exceeded" >&2; exit 1; }
case "\$*" in
  "api repos/Benjis-Plants/scheduler --jq .full_name") echo "Benjis-Plants/benjis-ops-tool" ;;
  "api repos/"*" --jq .full_name") r=\${2#repos/}; echo "\$r" ;;
  "api -X GET search/issues"*) cat "$DUP_DIR/search.json" ;;
  *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$DUP_DIR/bin/gh"
  DUP_OLDPATH=$PATH
  PATH="$DUP_DIR/bin:$PATH"
  export DEDUPE_CACHE_DIR="$DUP_DIR/cache" DEDUPE_GUARD_LOG="$DUP_DIR/guard.log"
}
dup_teardown() { PATH=$DUP_OLDPATH; rm -rf "$DUP_DIR"; unset DEDUPE_CACHE_DIR DEDUPE_GUARD_LOG; }

dup_hook() {  # dup_hook <command> [pipeline-agent] -> DUP_OUT = stderr, returns hook exit code
  local input rc
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$DUP_DIR")
  DUP_OUT=$(printf '%s' "$input" | PIPELINE_AGENT="${2:-}" DEDUPE_FIND_CMD="$FIND_DUP" bash "$HOOK_DUP" 2>&1 >/dev/null)
  rc=$?
  return "$rc"
}

test_dup_regression_2016_finds_1840_1841() {
  dup_setup
  local out rc
  out=$("$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE" "$T2016_BODY"); rc=$?
  dup_teardown
  assert_eq "$rc" "1" "#2016 must exit non-zero (strong candidate)" || return 1
  assert_contains "$out" "STRONG   Benjis-Plants/benjis-ops-tool#1840" "#1840 strong" || return 1
  assert_contains "$out" "STRONG   Benjis-Plants/benjis-ops-tool#1841" "#1841 strong" || return 1
  assert_contains "$out" "https://github.com/Benjis-Plants/benjis-ops-tool/issues/1841" "url printed" || return 1
  assert_contains "$out" "[agent-in-progress, user-feedback]" "labels printed" || return 1
  assert_not_contains "$out" "STRONG   Benjis-Plants/benjis-ops-tool#2045" "unrelated checkout bug is not strong" || return 1
  assert_not_contains "$out" "#1500" "unrelated ticket not listed" || return 1
}

test_dup_title_only_still_finds_2016_dupes() {
  dup_setup
  local out rc
  out=$("$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE"); rc=$?
  dup_teardown
  assert_eq "$rc" "1" "title alone is enough" || return 1
  assert_contains "$out" "#1841" "title-only #1841" || return 1
}

test_dup_reworded_requests_still_match() {
  # The raw in-app feedback title of #2016, and a request worded the way JP would say it.
  dup_setup
  local out1 rc1 out2 rc2
  out1=$("$FIND_DUP" Benjis-Plants/scheduler "Note and report at the checkout, can we have just one of the"); rc1=$?
  out2=$("$FIND_DUP" Benjis-Plants/scheduler "Tech app checkout: let technicians type the note once instead of in both the report and the notes box" \
    "Technicians enter the same information twice at checkout (visit report, then the notes box). One field would save time."); rc2=$?
  dup_teardown
  assert_eq "$rc1" "1" "raw feedback title" || return 1
  assert_contains "$out1" "STRONG   Benjis-Plants/benjis-ops-tool#1840" "raw title finds #1840" || return 1
  assert_eq "$rc2" "1" "paraphrase" || return 1
  assert_contains "$out2" "STRONG   Benjis-Plants/benjis-ops-tool#1841" "paraphrase finds #1841" || return 1
}

test_dup_unrelated_title_exits_zero() {
  dup_setup
  local out rc
  out=$("$FIND_DUP" Benjis-Plants/scheduler "Send invoice reminders to clients by email"); rc=$?
  dup_teardown
  assert_eq "$rc" "0" "no strong candidate" || return 1
  assert_not_contains "$out" "STRONG" "no STRONG line" || return 1
}

test_dup_searches_canonical_sibling_open_closed_prs() {
  dup_setup
  "$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE" "$T2016_BODY" >/dev/null
  local log n
  log=$(cat "$DUP_DIR/gh.log")
  n=$(grep -c "search/issues" "$DUP_DIR/gh.log")
  dup_teardown
  assert_contains "$log" "repo:Benjis-Plants/benjis-ops-tool" "renamed repo resolved to canonical" || return 1
  assert_not_contains "$log" "is:open" "never limited to open" || return 1
  assert_not_contains "$log" "is:issue" "PRs included" || return 1
  assert_not_contains "$log" "label:" "never limited by label" || return 1
  [ "$n" -ge 3 ] || { fail "expected several searches, got $n"; return 1; }
}

test_dup_quoting_tool_group() {
  dup_setup
  "$FIND_DUP" Benjis-Plants/benjis-quoting-tool "Quote PDF misses the delivery fee" >/dev/null
  local log; log=$(cat "$DUP_DIR/gh.log")
  dup_teardown
  assert_contains "$log" "repo:Benjis-Plants/benjis-quoting-tool" "quoting tool searched" || return 1
  assert_contains "$log" "repo:Benjis-Plants/benjis-sales-tool" "sales tool alias searched" || return 1
}

test_dup_exclude_and_search_failure() {
  dup_setup
  local out rc
  out=$("$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE" --exclude 1840 --exclude 1841); rc=$?
  assert_not_contains "$out" "#1841 " "excluded" || { dup_teardown; return 1; }
  rm -rf "$DUP_DIR/cache"; touch "$DUP_DIR/fail"
  out=$("$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE" 2>&1); rc=$?
  dup_teardown
  assert_eq "$rc" "3" "search failure is its own exit code" || return 1
  assert_contains "$out" "no duplicate check was possible" "failure said plainly" || return 1
}

test_dup_usage_error() {
  "$FIND_DUP" not-a-repo "" >/dev/null 2>&1
  assert_eq "$?" "2" "usage exit 2" || return 1
}

test_dup_no_secrets_in_output() {
  dup_setup
  local out; out=$(GH_TOKEN=ghp_fakefakefakefakefakefakefakefakefake1 "$FIND_DUP" Benjis-Plants/scheduler "$T2016_TITLE" 2>&1)
  dup_teardown
  assert_not_contains "$out" "ghp_" "token never printed" || return 1
  assert_not_contains "$out" "Technicians retype" "bodies never printed" || return 1
}

test_dup_hook_blocks_first_attempt_of_2016() {
  dup_setup
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body \"Technicians type the same visit information twice at checkout\""
  local rc=$?
  dup_teardown
  assert_eq "$rc" "2" "blocked" || return 1
  assert_contains "$DUP_OUT" "#1840" "lists #1840" || return 1
  assert_contains "$DUP_OUT" "#1841" "lists #1841" || return 1
  assert_contains "$DUP_OUT" "Dup-check: reviewed" "tells how to retry" || return 1
  assert_contains "$DUP_OUT" "comment on it" "tells to extend the existing ticket instead" || return 1
}

test_dup_hook_blocks_pipeline_agents_too() {
  dup_setup
  dup_hook "gh issue create --repo Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body x" product-manager
  local rc=$?
  dup_teardown
  assert_eq "$rc" "2" "PIPELINE_AGENT does not bypass" || return 1
}

test_dup_hook_retry_with_dup_check_goes_through() {
  dup_setup
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body \"Pre-fill the box.
Dup-check: reviewed #1840, #1841 — differs because this only pre-fills the Quick Log box\""
  local rc=$? log; log=$(cat "$DUP_DIR/guard.log")
  dup_teardown
  assert_eq "$rc" "0" "acknowledged retry allowed" || return 1
  assert_contains "$log" "allowed-acknowledged" "logged" || return 1
}

test_dup_hook_dup_check_must_name_every_candidate_and_reason() {
  dup_setup
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body \"Dup-check: reviewed #1840 — differs because this only pre-fills the box\""
  local rc1=$? out1=$DUP_OUT
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body \"Dup-check: #1840 #1841\""
  local rc2=$? out2=$DUP_OUT
  dup_teardown
  assert_eq "$rc1" "2" "missing #1841 blocked" || return 1
  assert_contains "$out1" "does not name: #1841" "names the missing one" || return 1
  assert_eq "$rc2" "2" "no reason blocked" || return 1
  assert_contains "$out2" "gives no reason" "asks for the reason" || return 1
}

test_dup_hook_shell_comment_and_parent_line_count() {
  dup_setup
  dup_hook "# Dup-check: reviewed #1840 — differs because this is the UI slice of it
gh issue create -R Benjis-Plants/scheduler --title \"$T2016_TITLE\" --body \"Parent: Benjis-Plants/scheduler#1841\""
  local rc=$?
  dup_teardown
  assert_eq "$rc" "0" "comment ack + Parent ack" || return 1
}

test_dup_hook_body_file_and_gh_api_post() {
  dup_setup
  printf 'Body\nDup-check: reviewed #1840, #1841 — differs because it covers contractors only\n' > "$DUP_DIR/body.md"
  dup_hook "gh issue create -R Benjis-Plants/scheduler -t \"$T2016_TITLE\" --body-file body.md"
  local rc1=$?
  dup_hook "gh api repos/Benjis-Plants/scheduler/issues -f title=\"$T2016_TITLE\" -f body=\"x\""
  local rc2=$?
  dup_hook "gh api -X POST repos/Benjis-Plants/scheduler/issues --input body.json"
  local rc3=$?
  dup_teardown
  assert_eq "$rc1" "0" "body-file read relative to cwd" || return 1
  assert_eq "$rc2" "2" "gh api issues POST checked" || return 1
  assert_eq "$rc3" "2" "unreadable POST still blocked (no title)" || return 1
}

test_dup_hook_ignores_non_create_commands() {
  dup_setup
  local c rc
  for c in "gh issue list -R Benjis-Plants/scheduler --search checkout" \
           "gh api repos/Benjis-Plants/scheduler/issues/1840/comments -f body=hi" \
           "gh api repos/Benjis-Plants/scheduler/issues/1840/labels -f labels[]=x" \
           "gh api -X GET repos/Benjis-Plants/scheduler/issues" \
           "gh issue create --help" "ls -la"; do
    dup_hook "$c"; rc=$?
    [ "$rc" = "0" ] || { dup_teardown; fail "should pass: $c ($DUP_OUT)"; return 1; }
  done
  [ -e "$DUP_DIR/gh.log" ] && { dup_teardown; fail "non-create command searched GitHub"; return 1; }
  dup_teardown
}

test_dup_hook_no_candidates_passes_and_failure_blocks() {
  dup_setup
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"Send invoice reminders to clients by email\" --body x"
  local rc1=$?
  touch "$DUP_DIR/fail"; rm -rf "$DUP_DIR/cache"
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"Send invoice reminders to clients by email\" --body x"
  local rc2=$? out2=$DUP_OUT
  dup_hook "gh issue create -R Benjis-Plants/scheduler --title \"Send invoice reminders\" --body \"Dup-check: searched by hand, nothing about invoice reminders exists\""
  local rc3=$?
  dup_teardown
  assert_eq "$rc1" "0" "no candidate → allowed" || return 1
  assert_eq "$rc2" "2" "search down → not silently skipped" || return 1
  assert_contains "$out2" "could not run" "says why" || return 1
  assert_eq "$rc3" "0" "search down + Dup-check reason → allowed" || return 1
}

test_dup_hook_wired_in_settings() {
  local n
  n=$(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
print(sum(1 for e in s["hooks"]["PreToolUse"] if e.get("matcher") == "Bash"
          for h in e["hooks"] if h.get("command") == "~/.claude/hooks/dedupe-ticket-guard.sh"))' "$ROOT_DUP/settings.json")
  assert_eq "$n" "1" "wired once on the Bash matcher" || return 1
}

test_dup_ticket_filers_told_to_search_first() {
  local f
  for f in agents/intake.md agents/product-manager.md agents/delivery-lead.md agents/pipeline-adjudicator.md agents/solutions-architect.md CLAUDE.md; do
    grep -qF 'find-duplicates.sh' "$ROOT_DUP/$f" || { fail "$f does not name find-duplicates.sh"; return 1; }
  done
  grep -qF -- '--label user-feedback --search' "$ROOT_DUP/agents/intake.md" && { fail "intake still searches only the user-feedback label"; return 1; }
  return 0
}

run_test test_dup_regression_2016_finds_1840_1841
run_test test_dup_title_only_still_finds_2016_dupes
run_test test_dup_reworded_requests_still_match
run_test test_dup_unrelated_title_exits_zero
run_test test_dup_searches_canonical_sibling_open_closed_prs
run_test test_dup_quoting_tool_group
run_test test_dup_exclude_and_search_failure
run_test test_dup_usage_error
run_test test_dup_no_secrets_in_output
run_test test_dup_hook_blocks_first_attempt_of_2016
run_test test_dup_hook_blocks_pipeline_agents_too
run_test test_dup_hook_retry_with_dup_check_goes_through
run_test test_dup_hook_dup_check_must_name_every_candidate_and_reason
run_test test_dup_hook_shell_comment_and_parent_line_count
run_test test_dup_hook_body_file_and_gh_api_post
run_test test_dup_hook_ignores_non_create_commands
run_test test_dup_hook_no_candidates_passes_and_failure_blocks
run_test test_dup_hook_wired_in_settings
run_test test_dup_ticket_filers_told_to_search_first
