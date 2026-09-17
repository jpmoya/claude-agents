# AC1     — pipeline-bridge-dispatch.sh exists, is executable, usage is `<issue> <repo-or-dash>`
#           (arg 2 required, not omittable).
# AC2     — an issue arg not matching ^[0-9]+$ ("abc", "", the injection string) exits non-zero,
#           prints a diagnostic, and makes zero `gh` calls — before any `gh` call.
# AC3     — `<issue> -` with no local orch-<issue>.repo file: exit 0, stdout is exactly one line
#           asking which repo, zero `gh` calls.
# AC4     — `<issue> -` with a local orch-<issue>.repo fixture: resolves owner/repo from that
#           checkout and proceeds through AC6-9 exactly as `<issue> owner/repo` would.
# AC5     — `<issue> owner/repo` where `gh repo view --repo owner/repo` fails: exit 0, stdout says
#           the repo couldn't be found, zero `gh issue` calls.
# AC6-9   — resolved repo + CLOSED / agent-in-progress / agent-go / neither: idempotent no-op for
#           the first three, exactly one `gh issue edit --repo <owner/repo> <issue> --add-label
#           agent-go` call for the last.
# AC10    — on any exit 0, stdout is exactly one line (checked inline in every exit-0 case above).
# AC11-13 — grep-verifiable content in pipeline-bridge-prompt.md / supervisor.sh / README.md.
# AC14    — (partial, see run-tests.sh for the pass-in-full half) portability: none of the
#           macOS-bash-3.2-unsafe constructs test-ac11-portability.sh's $FORBIDDEN_RE forbids.
#
# Fixture/fake-gh pattern: tests/lib/fixture.sh's mk_fake_gh (a fake `gh` on PATH that logs every
# invocation to <dir>/gh-calls.log; see gh_calls/gh_call_count), following test-ac1-ac2-payload.sh
# and test-ac10-lock.sh's isolated-fixture-per-test style. The fake gh is installed into an
# isolated HOME's .local/bin (see run_dispatch) so config.sh's own PATH prepend of
# "$HOME/.local/bin:..." can't let a real `gh` on this machine win the lookup ahead of the fake.
#
# Wording note: ACs 3, 5-9 don't hand this suite exact copy for the Slack-reply line (unlike a UX
# flow's States table) — Expected Behavior/AC text gives only a handful of keywords ("repo",
# "closed", "running", "queued", "dispatcher", "couldn't be found"). Assertions below check exactly
# those AC-derived keywords plus the single-line shape (AC10), never an invented full sentence.

HERE_PBD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE_PBD/../pipeline-bridge-dispatch.sh"
PROMPT_MD="$HERE_PBD/../pipeline-bridge-prompt.md"
SUPERVISOR_SH="$HERE_PBD/../supervisor.sh"
README_MD="$HERE_PBD/../../../README.md"

# run_dispatch <pipe> <home> <ghdir> <issue> <repo-or-dash> — runs the script under test with an
# isolated PIPE/QUEUE/HOME and the fake `gh` (already installed at <ghdir> by the caller) winning
# PATH lookups; sets RC and OUT (stdout only; a diagnostic on invalid input is not pinned to
# stderr vs stdout by the ticket, so AC2 only asserts exit code + call count, not stream).
run_dispatch() {
  local pipe=$1 home=$2 ghdir=$3 issue=$4 repo=$5
  OUT=$(PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT" "$issue" "$repo" 2>/tmp/pbd-stderr.$$)
  RC=$?
  ERR=$(cat /tmp/pbd-stderr.$$ 2>/dev/null)
  rm -f /tmp/pbd-stderr.$$
}

# new_gh_home — a new_home() with the fake gh pre-installed at $home/.local/bin (the directory
# config.sh's own PATH prepend puts first, so it beats a real `gh` elsewhere on this machine).
# Prints "<home> <ghdir>".
new_gh_home() {
  local home ghdir
  home=$(new_home)
  ghdir="$home/.local/bin"
  mk_fake_gh "$ghdir"
  echo "$home" "$ghdir"
}

assert_single_line() {  # assert_single_line <text> <label> — non-empty and contains no embedded newline
  case "$1" in
    *$'\n'*) fail "$2: expected exactly one line, got multiple:
$1"; return 1 ;;
  esac
  [ -n "$1" ] || { fail "$2: expected exactly one non-empty line, got empty output"; return 1; }
}

# ---------------------------------------------------------------------------
# AC1 — exists, executable, arg 2 required
# ---------------------------------------------------------------------------

test_ac1_script_exists_and_executable() {
  assert_file_exists "$SCRIPT" "AC1: pipeline-bridge-dispatch.sh must exist" || return 1
  [ -x "$SCRIPT" ] || { fail "AC1: pipeline-bridge-dispatch.sh must be executable"; return 1; }
}

test_ac1_missing_repo_arg_rejected() {
  local pipe home ghdir rc
  pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
  PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT" 123 >/dev/null 2>&1
  rc=$?
  rm -rf "$pipe" "$home"
  assert_ne "$rc" "0" "AC1: arg 2 (repo-or-dash) is required — omitting it must not exit 0" || return 1
}

test_ac1_zero_args_rejected() {
  local pipe home ghdir rc
  pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
  PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT" >/dev/null 2>&1
  rc=$?
  rm -rf "$pipe" "$home"
  assert_ne "$rc" "0" "AC1: zero args must not exit 0" || return 1
}

# ---------------------------------------------------------------------------
# AC2 — invalid issue arg: non-zero exit, diagnostic, zero gh calls, before any gh call
# ---------------------------------------------------------------------------

test_ac2_invalid_issue_arg_rejected() {
  local pipe home ghdir bad calls
  for bad in "abc" "" "7;rm -rf /tmp"; do
    pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
    run_dispatch "$pipe" "$home" "$ghdir" "$bad" "-"
    calls=$(gh_call_count "$ghdir" "")
    rm -rf "$pipe" "$home"
    assert_ne "$RC" "0" "AC2: issue arg [$bad] must exit non-zero" || return 1
    assert_eq "$calls" "0" "AC2: issue arg [$bad] must make zero gh calls" || return 1
    [ -n "$ERR$OUT" ] || { fail "AC2: issue arg [$bad] must print a diagnostic (stdout or stderr)"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# AC3 — "-" with no local orch-<issue>.repo file
# ---------------------------------------------------------------------------

test_ac3_dash_no_repo_file_asks_which_repo() {
  local pipe home ghdir calls
  pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
  run_dispatch "$pipe" "$home" "$ghdir" 301 "-"
  calls=$(gh_call_count "$ghdir" "")
  rm -rf "$pipe" "$home"
  assert_exit0 "$RC" "AC3: no local .repo file, exits 0" || return 1
  assert_single_line "$OUT" "AC3: stdout is exactly one line" || return 1
  assert_contains "$OUT" "repo" "AC3: stdout asks which repo (must mention \"repo\")" || return 1
  assert_eq "$calls" "0" "AC3: zero gh calls when no repo can be resolved" || return 1
}

# ---------------------------------------------------------------------------
# AC4 — "-" with a local orch-<issue>.repo fixture resolves and proceeds exactly as an explicit
#        owner/repo would (checked against the AC9 "neither label" outcome).
# ---------------------------------------------------------------------------

test_ac4_dash_with_repo_fixture_matches_explicit_repo_outcome() {
  local pipe home1 ghdir1 home2 ghdir2 repo_checkout owner_repo
  local out_explicit out_dash edits1 edits2 edit_line1 edit_line2
  owner_repo="example-owner/project-a"
  pipe=$(new_pipe)
  repo_checkout="$pipe/repo-project-a"
  fixture_repo "$repo_checkout" "$owner_repo"
  echo "$repo_checkout" > "$pipe/orch-401.repo"

  # Path 1: explicit owner/repo arg.
  read -r home1 ghdir1 <<< "$(new_gh_home)"
  echo "$owner_repo" > "$ghdir1/gh-name-with-owner"
  echo "OPEN" > "$ghdir1/gh-issue-state"
  echo "[]" > "$ghdir1/gh-issue-labels-json"
  run_dispatch "$pipe" "$home1" "$ghdir1" 401 "$owner_repo"
  out_explicit=$OUT
  edits1=$(gh_call_count "$ghdir1" "issue edit")
  edit_line1=$(grep "issue edit" "$ghdir1/gh-calls.log" 2>/dev/null | head -1)

  # Path 2: "-" resolved from the local checkout fixture. Same fake-gh responses so any resolution
  # mechanism (git remote parse, `gh repo view --json nameWithOwner`, ...) yields the same repo.
  read -r home2 ghdir2 <<< "$(new_gh_home)"
  echo "$owner_repo" > "$ghdir2/gh-name-with-owner"
  echo "OPEN" > "$ghdir2/gh-issue-state"
  echo "[]" > "$ghdir2/gh-issue-labels-json"
  run_dispatch "$pipe" "$home2" "$ghdir2" 401 "-"
  out_dash=$OUT
  edits2=$(gh_call_count "$ghdir2" "issue edit")
  edit_line2=$(grep "issue edit" "$ghdir2/gh-calls.log" 2>/dev/null | head -1)

  rm -rf "$pipe" "$home1" "$home2"

  assert_single_line "$out_dash" "AC4/AC10: the '-'-resolved reply is exactly one line too" || return 1
  assert_eq "$out_dash" "$out_explicit" "AC4: '-' resolved via the local checkout must produce the same reply as the explicit owner/repo" || return 1
  assert_eq "$edits1" "1" "AC4: explicit-repo path must make exactly one edit call (AC9 baseline)" || return 1
  assert_eq "$edits2" "1" "AC4: '-'-resolved path must make exactly one edit call, same as the explicit-repo path" || return 1
  assert_contains "$edit_line2" "--repo $owner_repo" "AC4: the '-'-resolved edit call must target the owner/repo actually derived from the checkout, not a placeholder/garbage value" || return 1
}

# ---------------------------------------------------------------------------
# AC5 — explicit owner/repo, `gh repo view --repo` fails
# ---------------------------------------------------------------------------

test_ac5_repo_view_fails_reports_not_found() {
  local pipe home ghdir issue_calls repo_view_calls
  pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
  echo 1 > "$ghdir/gh-repo-view-rc"
  run_dispatch "$pipe" "$home" "$ghdir" 501 "owner/repo"
  issue_calls=$(gh_call_count "$ghdir" "issue")
  repo_view_calls=$(gh_call_count "$ghdir" "repo view")
  rm -rf "$pipe" "$home"
  assert_exit0 "$RC" "AC5: unreachable repo still exits 0" || return 1
  assert_single_line "$OUT" "AC5: stdout is exactly one line" || return 1
  assert_contains "$OUT" "couldn't be found" "AC5: stdout says the repo couldn't be found" || return 1
  assert_eq "$issue_calls" "0" "AC5: zero gh issue calls when the repo itself can't be found" || return 1
  assert_ne "$repo_view_calls" "0" "AC5: gh repo view must actually have been attempted (a no-op stub that never tries would pass the issue_calls=0 check vacuously)" || return 1
}

# ---------------------------------------------------------------------------
# AC6-9 — resolved repo, varied state/labels
# ---------------------------------------------------------------------------

# run_state_scenario <issue> <state> <labels-json> — shared setup+teardown for AC6-9 against a
# resolved "example-owner/project-a". Sets OUT/RC/ERR (via run_dispatch) plus SCEN_ISSUE_VIEW_CALLS/
# SCEN_EDIT_CALLS/SCEN_EDIT_LINE — all captured before pipe/home (and the fake gh's log with them)
# are torn down.
run_state_scenario() {
  local issue=$1 state=$2 labels=$3
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(new_gh_home)"
  echo "example-owner/project-a" > "$ghdir/gh-name-with-owner"
  echo "$state" > "$ghdir/gh-issue-state"
  echo "$labels" > "$ghdir/gh-issue-labels-json"
  run_dispatch "$pipe" "$home" "$ghdir" "$issue" "example-owner/project-a"
  SCEN_ISSUE_VIEW_CALLS=$(gh_call_count "$ghdir" "issue view")
  SCEN_EDIT_CALLS=$(gh_call_count "$ghdir" "issue edit")
  SCEN_EDIT_LINE=$(grep "issue edit" "$ghdir/gh-calls.log" 2>/dev/null | head -1)
  rm -rf "$pipe" "$home"
}

test_ac6_closed_is_idempotent_noop() {
  run_state_scenario 601 "CLOSED" "[]"
  assert_exit0 "$RC" "AC6: closed issue exits 0" || return 1
  assert_single_line "$OUT" "AC6: stdout is exactly one line" || return 1
  assert_contains "$OUT" "already closed" "AC6: stdout says the issue is already closed" || return 1
  assert_eq "$SCEN_EDIT_CALLS" "0" "AC6: zero gh issue edit calls for a closed issue" || return 1
  assert_ne "$SCEN_ISSUE_VIEW_CALLS" "0" "AC6: gh issue view must actually have been attempted (else the edit-calls=0 check is vacuous)" || return 1
}

test_ac7_agent_in_progress_is_idempotent_noop() {
  run_state_scenario 701 "OPEN" '[{"name":"agent-in-progress"}]'
  assert_exit0 "$RC" "AC7: agent-in-progress exits 0" || return 1
  assert_single_line "$OUT" "AC7: stdout is exactly one line" || return 1
  assert_contains "$OUT" "already running" "AC7: stdout says it's already running" || return 1
  assert_eq "$SCEN_EDIT_CALLS" "0" "AC7: zero gh issue edit --add-label agent-go calls while agent-in-progress" || return 1
  assert_ne "$SCEN_ISSUE_VIEW_CALLS" "0" "AC7: gh issue view must actually have been attempted (else the edit-calls=0 check is vacuous)" || return 1
}

test_ac8_agent_go_already_set_is_idempotent_noop() {
  run_state_scenario 801 "OPEN" '[{"name":"agent-go"}]'
  assert_exit0 "$RC" "AC8: agent-go already set exits 0" || return 1
  assert_single_line "$OUT" "AC8: stdout is exactly one line" || return 1
  assert_contains "$OUT" "already queued" "AC8: stdout says it's already queued" || return 1
  assert_eq "$SCEN_EDIT_CALLS" "0" "AC8: zero additional gh issue edit --add-label agent-go calls — never relabel" || return 1
  assert_ne "$SCEN_ISSUE_VIEW_CALLS" "0" "AC8: gh issue view must actually have been attempted (else the edit-calls=0 check is vacuous)" || return 1
}

test_ac9_neither_label_open_dispatches() {
  run_state_scenario 901 "OPEN" "[]"
  assert_exit0 "$RC" "AC9: neither label, OPEN, exits 0" || return 1
  assert_single_line "$OUT" "AC9: stdout is exactly one line" || return 1
  assert_contains "$OUT" "queued" "AC9: stdout says it's queued" || return 1
  assert_contains "$OUT" "dispatcher" "AC9: stdout says it will be picked up by the shared dispatcher" || return 1
  assert_eq "$SCEN_EDIT_CALLS" "1" "AC9: exactly one gh issue edit call" || return 1
  assert_contains "$SCEN_EDIT_LINE" "--repo example-owner/project-a" "AC9: the edit call must target --repo <owner/repo>" || return 1
  assert_contains "$SCEN_EDIT_LINE" "901" "AC9: the edit call must target issue 901" || return 1
  assert_contains "$SCEN_EDIT_LINE" "--add-label agent-go" "AC9: the edit call must add the agent-go label" || return 1
}

# ---------------------------------------------------------------------------
# AC11 — pipeline-bridge-prompt.md: grep-verifiable content
# ---------------------------------------------------------------------------

test_ac11_prompt_md_exists_and_has_required_content() {
  assert_file_exists "$PROMPT_MD" "AC11: pipeline-bridge-prompt.md must exist" || return 1
  local body
  body=$(cat "$PROMPT_MD" 2>/dev/null)
  assert_contains "$body" "skills/orchestrate/pipeline-bridge-dispatch.sh" "AC11: must contain the literal script path" || return 1
  assert_contains "$body" "verbatim" "AC11: must instruct relaying stdout verbatim on exit 0" || return 1
  assert_contains "$body" "generic failure" "AC11: must instruct a generic failure line on non-zero" || return 1
  assert_contains "$body" "never guess or retry" "AC11: must forbid guessing or retrying" || return 1
  assert_contains "$body" "#<digits>" "AC11: must document the issue-number extraction rule (first #<digits>)" || return 1
  assert_contains "$body" "<owner>/<repo>" "AC11: must document the optional owner/repo token extraction rule" || return 1
}

# ---------------------------------------------------------------------------
# AC12 — supervisor.sh's Slack reply bridge comment: no longer DISABLED, names both tracked files
# ---------------------------------------------------------------------------

test_ac12_supervisor_comment_updated() {
  local body
  body=$(cat "$SUPERVISOR_SH" 2>/dev/null)
  assert_not_contains "$body" "DISABLED" "AC12: the Slack reply bridge comment must no longer say DISABLED" || return 1
  assert_contains "$body" "pipeline-bridge-dispatch.sh" "AC12: the comment must name pipeline-bridge-dispatch.sh by path" || return 1
  assert_contains "$body" "pipeline-bridge-prompt.md" "AC12: the comment must name pipeline-bridge-prompt.md by path" || return 1
}

# ---------------------------------------------------------------------------
# AC13 — README.md documents the manual install step
# ---------------------------------------------------------------------------

test_ac13_readme_documents_manual_install_step() {
  local body
  body=$(cat "$README_MD" 2>/dev/null)
  assert_contains "$body" "pipeline-bridge-prompt.md" "AC13: README.md must mention pipeline-bridge-prompt.md" || return 1
}

# ---------------------------------------------------------------------------
# AC14 — portability: none of test-ac11-portability.sh's forbidden macOS-bash-3.2-unsafe constructs
# appear in the new script. Reuses $FORBIDDEN_RE from that file rather than re-spelling the
# forbidden words here: run-tests.sh sources test-*.sh alphabetically, so "test-ac11-portability.sh"
# (defines $FORBIDDEN_RE) runs before this file ("test-pipeline-..."), and re-spelling those words
# literally in this file's source would itself trip test-ac11's own "no test file contains these
# words" scan.
# ---------------------------------------------------------------------------

test_ac14_pipeline_bridge_dispatch_no_forbidden_syntax() {
  if [ -z "${FORBIDDEN_RE:-}" ]; then
    fail "AC14: \$FORBIDDEN_RE not set — expected test-ac11-portability.sh to run first (run-tests.sh sources test-*.sh alphabetically)"
    return 1
  fi
  local hits
  hits=$(grep -nE "$FORBIDDEN_RE" "$SCRIPT" 2>/dev/null || true)
  assert_eq "$hits" "" "AC14: pipeline-bridge-dispatch.sh must contain none of the forbidden, non-macOS-bash-3.2-safe constructs" || return 1
}

run_test test_ac1_script_exists_and_executable
run_test test_ac1_missing_repo_arg_rejected
run_test test_ac1_zero_args_rejected
run_test test_ac2_invalid_issue_arg_rejected
run_test test_ac3_dash_no_repo_file_asks_which_repo
run_test test_ac4_dash_with_repo_fixture_matches_explicit_repo_outcome
run_test test_ac5_repo_view_fails_reports_not_found
run_test test_ac6_closed_is_idempotent_noop
run_test test_ac7_agent_in_progress_is_idempotent_noop
run_test test_ac8_agent_go_already_set_is_idempotent_noop
run_test test_ac9_neither_label_open_dispatches
run_test test_ac11_prompt_md_exists_and_has_required_content
run_test test_ac12_supervisor_comment_updated
run_test test_ac13_readme_documents_manual_install_step
run_test test_ac14_pipeline_bridge_dispatch_no_forbidden_syntax
