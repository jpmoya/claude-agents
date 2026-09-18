# AC1     — pipeline-bridge-dispatch.sh exists, is executable, usage is `<issue> <repo-or-dash>`
#           (arg 2 required, not omittable).
# AC2     — an issue arg not matching ^[0-9]+$ ("abc", "", the injection string) exits non-zero,
#           prints a diagnostic, and makes zero `gh` calls — before any `gh` call.
# AC3     — `<issue> -` with no local orch-<issue>.repo file: exit 0, stdout is exactly one line
#           asking which repo, zero `gh` calls.
# AC4     — `<issue> -` with a local orch-<issue>.repo fixture: resolves owner/repo from that
#           checkout and proceeds through AC6-9 exactly as `<issue> owner/repo` would. The
#           checkout's fixture repo is given an owner/repo that appears in no fake-gh config file
#           (only in the checkout's real git remote), so the test is falsifiable: an implementation
#           that doesn't actually read the checkout can't coincidentally produce the right value.
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
  OUT=$(PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT" "$issue" "$repo" "C0PBDTEST" "1700000000.000100" 2>/tmp/pbd-stderr.$$)
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
  local pipe home1 ghdir1 home2 ghdir2 repo_checkout
  local owner_repo_explicit owner_repo_checkout
  local out_dash edits1 edits2 edit_line1 edit_line2
  # Deliberately distinct owner/repo values, and — critically — owner_repo_checkout appears in NO
  # fake-gh config file, only in the checkout's real git remote (via fixture_repo). This is what
  # makes the test falsifiable: an implementation that never reads $PIPE/orch-401.repo and instead
  # calls e.g. `gh repo view --json nameWithOwner` unconditionally would get ghdir2's canned
  # default ("unknown/unknown", since gh-name-with-owner is never written for ghdir2's repo-view
  # form) or path1's value — never "project-b" — and this test would correctly fail. Only a script
  # that actually parses the checkout's own git remote can produce "project-b" here.
  owner_repo_explicit="example-owner/project-a"
  owner_repo_checkout="example-owner/project-b"
  pipe=$(new_pipe)
  repo_checkout="$pipe/repo-project-b"
  fixture_repo "$repo_checkout" "$owner_repo_checkout"
  echo "$repo_checkout" > "$pipe/orch-401.repo"

  # Path 1: explicit owner/repo arg. Same $pipe (so orch-401.repo is present here too) — proves an
  # explicit arg wins over the local .repo file rather than the .repo file being consulted first.
  read -r home1 ghdir1 <<< "$(new_gh_home)"
  echo "$owner_repo_explicit" > "$ghdir1/gh-name-with-owner"
  echo "OPEN" > "$ghdir1/gh-issue-state"
  echo "[]" > "$ghdir1/gh-issue-labels-json"
  run_dispatch "$pipe" "$home1" "$ghdir1" 401 "$owner_repo_explicit"
  edits1=$(gh_call_count "$ghdir1" "issue edit")
  edit_line1=$(grep "issue edit" "$ghdir1/gh-calls.log" 2>/dev/null | head -1)

  # Path 2: "-" resolved from the local checkout fixture. gh-name-with-owner is deliberately left
  # unset here (fake's default "unknown/unknown") for the reachability/labels calls — only the
  # checkout's real git remote carries "project-b". The reachability call's --repo arg is expected
  # to be owner_repo_checkout regardless of what the fake would otherwise report.
  read -r home2 ghdir2 <<< "$(new_gh_home)"
  echo "OPEN" > "$ghdir2/gh-issue-state"
  echo "[]" > "$ghdir2/gh-issue-labels-json"
  run_dispatch "$pipe" "$home2" "$ghdir2" 401 "-"
  out_dash=$OUT
  edits2=$(gh_call_count "$ghdir2" "issue edit")
  edit_line2=$(grep "issue edit" "$ghdir2/gh-calls.log" 2>/dev/null | head -1)

  rm -rf "$pipe" "$home1" "$home2"

  # AC4: "-" resolution must proceed through AC6-9's outcome exactly as an explicit owner/repo
  # would — checked here against the AC9 (neither label, OPEN) branch: single line, mentions
  # "queued" and "dispatcher" (not a copy-pasted-string comparison against path 1, which now
  # legitimately targets a different repo and could legitimately embed it in the reply).
  assert_single_line "$out_dash" "AC4/AC10: the '-'-resolved reply is exactly one line" || return 1
  assert_contains "$out_dash" "queued" "AC4: '-'-resolved reply says it's queued, same outcome as AC9" || return 1
  assert_contains "$out_dash" "dispatcher" "AC4: '-'-resolved reply mentions the shared dispatcher, same outcome as AC9" || return 1
  assert_eq "$edits1" "1" "AC4: explicit-repo path must make exactly one edit call (AC9 baseline)" || return 1
  assert_eq "$edits2" "1" "AC4: '-'-resolved path must make exactly one edit call, same as the explicit-repo path" || return 1
  assert_contains "$edit_line1" "--repo $owner_repo_explicit" "AC4: explicit-repo path's edit call must target the explicit arg, not the local .repo file" || return 1
  assert_contains "$edit_line2" "--repo $owner_repo_checkout" "AC4: the '-'-resolved edit call must target the owner/repo actually derived from the checkout ($owner_repo_checkout), not a placeholder/garbage/other-path value" || return 1
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
  # AC11's fourth content clause: an instruction that pipeline-bridge-dispatch.sh is the *only*
  # command the agent may execute in response to a mention (no freeform gh/git/shell). No exact
  # copy is given for this clause either, so tolerate reasonable rewordings around "only" +
  # "command" (e.g. "the only command you may run") rather than pinning adjacent substrings.
  echo "$body" | grep -Eqi "only[^.]*command" || { fail "AC11: must instruct that pipeline-bridge-dispatch.sh is the only command the agent may execute in response to a mention"; return 1; }
  assert_contains "$body" "freeform" "AC11: must forbid freeform gh/git/shell composed by the agent" || return 1
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

# ===========================================================================
# Issue #15 — slack-thread NOTE + the two new required args (<channel> <ts>)
#
# AC1     — closed / already-running / already-queued / newly-queued each post exactly one
#           `gh issue comment` whose body's FIRST line is
#           `**[pipeline-bridge] NOTE** slack-thread: <channel>:<ts>` (extra lines are allowed).
# AC2     — "repo not found" and "which repo?" post no comment.
# AC6     — pipeline-bridge-prompt.md documents extracting chat_id/message_id and always passing
#           them as args 3/4.
# AC7     — (dispatch-script half) portability, already enforced by test_ac14_* above; the
#           supervisor.sh half lives in test-notify-engineering-thread.sh.
# Expected Behavior 1 — the script now takes FOUR required positional args.
#
# The two args added to run_dispatch's argv and to test-pipeline-bridge-dispatch-error-handling.sh's
# two invocations are the only edits made to the #7 tests; no #7 assertion was touched.
#
# Fake gh: mk_fake_gh (tests/lib/fixture.sh) has no `issue comment` branch, so pbdt_gh_home wraps it:
# `issue comment` is intercepted (body captured to <ghdir>/comments/<n>.body, a URL printed on
# stdout like the real gh does so a leak into the script's own stdout is caught by the
# exactly-one-line assertion) and every other call is delegated unchanged to the base fake.
# ===========================================================================

PBDT_CHANNEL="C0123ABCD"
PBDT_TS="1726690000.000200"
PBDT_NOTE="**[pipeline-bridge] NOTE** slack-thread: $PBDT_CHANNEL:$PBDT_TS"
PBDT_ROOT=$(cd "$HERE_PBD/../../.." && pwd)

# pbdt_gh_home — like new_gh_home, but the fake gh also understands `gh issue comment`. Prints "<home> <ghdir>".
pbdt_gh_home() {
  local home ghdir
  home=$(new_home)
  ghdir="$home/.local/bin"
  mk_fake_gh "$ghdir"
  mv "$ghdir/gh" "$ghdir/gh-base"
  cat > "$ghdir/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  printf '%s\n' "$*" | tr '\n' ' ' >> "$HERE/gh-calls.log"; echo >> "$HERE/gh-calls.log"
  body="" prev=""
  for a in "$@"; do
    case "$prev" in
      --body|-b) body=$a ;;
      --body-file|-F) if [ "$a" = "-" ]; then body=$(cat); else body=$(cat "$a"); fi ;;
    esac
    case "$a" in --body=*) body=${a#--body=} ;; esac
    prev=$a
  done
  mkdir -p "$HERE/comments"
  n=$(ls "$HERE/comments" | wc -l | tr -d ' ')
  printf '%s' "$body" > "$HERE/comments/$((n + 1)).body"
  echo "https://github.com/example-owner/project-a/issues/$3#issuecomment-1"
  exit "$(cat "$HERE/gh-comment-rc" 2>/dev/null || echo 0)"
fi
exec "$HERE/gh-base" "$@"
GH_EOF
  chmod +x "$ghdir/gh"
  echo "$home" "$ghdir"
}

# pbdt_run <ghdir> <home> <pipe> <issue> <repo-or-dash> [<channel> <ts>] — runs the script with the
# given args (channel/ts omitted -> fewer args, for the arity tests); sets PBDT_RC, PBDT_OUT.
pbdt_run() {
  local ghdir=$1 home=$2 pipe=$3; shift 3
  PBDT_OUT=$(PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT" "$@" 2>/dev/null)
  PBDT_RC=$?
}

# pbdt_capture <ghdir> — sets PBDT_COMMENTS (number of captured comments), PBDT_COMMENT_1 (first
# comment's full body), PBDT_COMMENT_1_FIRST (its first line), PBDT_COMMENT_CALLS (log lines of
# comment calls), PBDT_TOTAL_CALLS, PBDT_EDITS.
pbdt_capture() {
  local ghdir=$1
  PBDT_COMMENTS=$(ls "$ghdir/comments" 2>/dev/null | wc -l | tr -d ' ')
  PBDT_COMMENT_1=$(cat "$ghdir/comments/1.body" 2>/dev/null)
  PBDT_COMMENT_1_FIRST=$(printf '%s\n' "$PBDT_COMMENT_1" | head -1)
  PBDT_COMMENT_CALLS=$(grep '^issue comment' "$ghdir/gh-calls.log" 2>/dev/null)
  PBDT_TOTAL_CALLS=$(gh_call_count "$ghdir" "")
  PBDT_EDITS=$(gh_call_count "$ghdir" "issue edit")
}

# pbdt_scenario <issue> <state> <labels-json> [<repo-arg>] — one run against example-owner/project-a
# with PBDT_CHANNEL/PBDT_TS; leaves PBDT_* captured (see pbdt_run / pbdt_capture) and cleans up.
pbdt_scenario() {
  local issue=$1 state=$2 labels=$3 repo=${4:-example-owner/project-a}
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo "$state" > "$ghdir/gh-issue-state"
  echo "$labels" > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" "$issue" "$repo" "$PBDT_CHANNEL" "$PBDT_TS"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
}

# pbdt_assert_one_note <issue> <label> — AC1's shared assertions after a pbdt_scenario run.
pbdt_assert_one_note() {
  local issue=$1 label=$2
  assert_exit0 "$PBDT_RC" "$label: exits 0" || return 1
  assert_single_line "$PBDT_OUT" "$label: stdout stays exactly one line (the gh comment call must not leak into it)" || return 1
  assert_eq "$PBDT_COMMENTS" "1" "$label: exactly one gh issue comment call" || return 1
  assert_eq "$PBDT_COMMENT_1_FIRST" "$PBDT_NOTE" "$label: comment body's first line" || return 1
  assert_contains "$PBDT_COMMENT_CALLS" "--repo example-owner/project-a" "$label: the comment targets the resolved repo" || return 1
  assert_contains "$PBDT_COMMENT_CALLS" " $issue " "$label: the comment targets issue $issue" || return 1
}

# ---------------------------------------------------------------------------
# AC1 — each real-issue outcome posts exactly one NOTE
# ---------------------------------------------------------------------------

test_t15_ac1_newly_queued_posts_one_thread_note() {
  pbdt_scenario 1501 "OPEN" "[]"
  pbdt_assert_one_note 1501 "AC1 newly-queued" || return 1
  assert_eq "$PBDT_EDITS" "1" "AC1 newly-queued: the agent-go label is still added exactly once (#7 AC9 unchanged)" || return 1
  assert_contains "$PBDT_OUT" "queued" "AC1 newly-queued: the Slack reply still says queued" || return 1
}

test_t15_ac1_note_is_inert_to_routing_markers() {
  # Expected Behavior 2: NOTE is deliberately outside hooks/pipeline-markers.sh's vocabulary.
  pbdt_scenario 1502 "OPEN" "[]"
  local re verdict
  re=$(. "$PBDT_ROOT/hooks/pipeline-markers.sh" && marker_re)
  assert_ne "$PBDT_COMMENT_1_FIRST" "" "AC1: a NOTE must have been posted for this inertness check to mean anything" || return 1
  verdict=$(jq -n --arg l "$PBDT_COMMENT_1_FIRST" --arg re "$re" '$l | test($re)')
  assert_eq "$verdict" "false" "AC1: the posted first line must NOT be a routing marker per marker_re" || return 1
}

test_t15_ac1_already_running_posts_one_thread_note() {
  pbdt_scenario 1503 "OPEN" '[{"name":"agent-in-progress"}]'
  pbdt_assert_one_note 1503 "AC1 already-running" || return 1
  assert_eq "$PBDT_EDITS" "0" "AC1 already-running: still no relabel" || return 1
  assert_contains "$PBDT_OUT" "already running" "AC1 already-running: the Slack reply is unchanged" || return 1
}

test_t15_ac1_already_queued_posts_one_thread_note() {
  pbdt_scenario 1504 "OPEN" '[{"name":"agent-go"}]'
  pbdt_assert_one_note 1504 "AC1 already-queued" || return 1
  assert_eq "$PBDT_EDITS" "0" "AC1 already-queued: still no relabel" || return 1
  assert_contains "$PBDT_OUT" "already queued" "AC1 already-queued: the Slack reply is unchanged" || return 1
}

test_t15_ac1_closed_posts_one_thread_note() {
  # AC1 / Expected Behavior 2 list "closed" among the outcomes that record the thread.
  # (The ticket's "Test fixtures" bullet says CLOSED posts no comment — that contradicts AC1 and
  # Expected Behavior 2; the ACs are followed. See the handoff.)
  pbdt_scenario 1505 "CLOSED" "[]"
  pbdt_assert_one_note 1505 "AC1 closed" || return 1
  assert_contains "$PBDT_OUT" "already closed" "AC1 closed: the Slack reply is unchanged" || return 1
}

test_t15_ac1_note_uses_the_channel_and_ts_args_verbatim() {
  # A second, different channel/ts pair, so an implementation that hard-codes or re-derives the
  # values cannot pass. Re-threading: a later mention from another thread records its own NOTE.
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo "OPEN" > "$ghdir/gh-issue-state"; echo '[{"name":"agent-go"}]' > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" 1506 "example-owner/project-a" "C9ZZZ9ZZZ" "1800000000.999999"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_eq "$PBDT_COMMENTS" "1" "AC1: exactly one comment" || return 1
  assert_eq "$PBDT_COMMENT_1_FIRST" "**[pipeline-bridge] NOTE** slack-thread: C9ZZZ9ZZZ:1800000000.999999" "AC1: first line carries the args it was given" || return 1
}

test_t15_ac1_dash_resolved_repo_gets_the_note_on_the_resolved_repo() {
  # Same falsifiable setup as #7's AC4: the checkout's remote (project-b) appears in no fake-gh
  # config, so the NOTE can only land on project-b if the script really resolved it.
  local pipe home ghdir repo_checkout
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  repo_checkout="$pipe/repo-project-b"
  fixture_repo "$repo_checkout" "example-owner/project-b"
  echo "$repo_checkout" > "$pipe/orch-1507.repo"
  echo "OPEN" > "$ghdir/gh-issue-state"; echo "[]" > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" 1507 "-" "$PBDT_CHANNEL" "$PBDT_TS"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_exit0 "$PBDT_RC" "AC1 dash: exits 0" || return 1
  assert_single_line "$PBDT_OUT" "AC1 dash: stdout stays exactly one line" || return 1
  assert_eq "$PBDT_COMMENTS" "1" "AC1 dash: exactly one comment" || return 1
  assert_eq "$PBDT_COMMENT_1_FIRST" "$PBDT_NOTE" "AC1 dash: first line" || return 1
  assert_contains "$PBDT_COMMENT_CALLS" "--repo example-owner/project-b" "AC1 dash: the NOTE goes to the repo resolved from the checkout" || return 1
}

# ---------------------------------------------------------------------------
# AC2 — no comment for "repo not found" / "which repo?". Each test first runs a positive control
# (a newly-queued run that MUST record a NOTE) so it cannot pass vacuously against a script that
# never posts any comment.
# ---------------------------------------------------------------------------

test_t15_ac2_repo_not_found_posts_no_comment() {
  pbdt_scenario 1601 "OPEN" "[]"
  assert_eq "$PBDT_COMMENTS" "1" "AC2 control: a newly-queued run must post its NOTE (else this test proves nothing)" || return 1

  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo 1 > "$ghdir/gh-repo-view-rc"
  pbdt_run "$ghdir" "$home" "$pipe" 1602 "example-owner/project-a" "$PBDT_CHANNEL" "$PBDT_TS"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_exit0 "$PBDT_RC" "AC2 repo-not-found: exits 0" || return 1
  assert_contains "$PBDT_OUT" "couldn't be found" "AC2 repo-not-found: reply unchanged" || return 1
  assert_eq "$PBDT_COMMENTS" "0" "AC2 repo-not-found: no comment body captured" || return 1
  assert_eq "$PBDT_COMMENT_CALLS" "" "AC2 repo-not-found: no gh issue comment call at all" || return 1
}

test_t15_ac2_which_repo_posts_no_comment() {
  pbdt_scenario 1603 "OPEN" "[]"
  assert_eq "$PBDT_COMMENTS" "1" "AC2 control: a newly-queued run must post its NOTE (else this test proves nothing)" || return 1

  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  pbdt_run "$ghdir" "$home" "$pipe" 1604 "-" "$PBDT_CHANNEL" "$PBDT_TS"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_exit0 "$PBDT_RC" "AC2 which-repo: exits 0" || return 1
  assert_contains "$PBDT_OUT" "repo" "AC2 which-repo: reply still asks which repo" || return 1
  assert_eq "$PBDT_TOTAL_CALLS" "0" "AC2 which-repo: zero gh calls of any kind (so no comment either)" || return 1
}

# ---------------------------------------------------------------------------
# Expected Behavior 1 — channel and ts are REQUIRED positional args (2- and 3-arg forms rejected,
# before any gh call, like #7's other usage errors).
# ---------------------------------------------------------------------------

test_t15_args_two_arg_form_is_rejected() {
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo "OPEN" > "$ghdir/gh-issue-state"; echo "[]" > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" 1701 "example-owner/project-a"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_ne "$PBDT_RC" "0" "Expected Behavior 1: <issue> <repo> alone (no channel/ts) must not exit 0" || return 1
  assert_eq "$PBDT_TOTAL_CALLS" "0" "Expected Behavior 1: rejected before any gh call" || return 1
}

test_t15_args_three_arg_form_is_rejected() {
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo "OPEN" > "$ghdir/gh-issue-state"; echo "[]" > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" 1702 "example-owner/project-a" "$PBDT_CHANNEL"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_ne "$PBDT_RC" "0" "Expected Behavior 1: <issue> <repo> <channel> without ts must not exit 0" || return 1
  assert_eq "$PBDT_TOTAL_CALLS" "0" "Expected Behavior 1: rejected before any gh call" || return 1
}

# ---------------------------------------------------------------------------
# AC6 — pipeline-bridge-prompt.md: chat_id / message_id extraction, always passed as args 3/4
# ---------------------------------------------------------------------------

test_t15_ac6_prompt_documents_chat_id_and_message_id_as_args_3_and_4() {
  local body
  body=$(cat "$PROMPT_MD" 2>/dev/null)
  assert_contains "$body" "chat_id" "AC6: must name the chat_id metadata field" || return 1
  assert_contains "$body" "message_id" "AC6: must name the message_id metadata field" || return 1
  assert_contains "$body" "channel:" "AC6: must mention the channel: prefix (which is stripped from chat_id)" || return 1
  assert_contains "$body" "<repo-or-dash> <channel> <ts>" "AC6: the command's usage line must show all four args (<issue> <repo-or-dash> <channel> <ts>)" || return 1
  echo "$body" | grep -Eqi 'always' || { fail "AC6: must say the two values are ALWAYS passed"; return 1; }
  echo "$body" | grep -Eqi '(arg(ument)?s?[[:space:]]*(3|three)|third)' || { fail "AC6: must say chat_id/message_id are passed as args 3 and 4"; return 1; }
  assert_not_contains "$body" "those two arguments" "AC6: the stale '... with those two arguments' instruction must be gone" || return 1
}

run_test test_t15_ac1_newly_queued_posts_one_thread_note
run_test test_t15_ac1_note_is_inert_to_routing_markers
run_test test_t15_ac1_already_running_posts_one_thread_note
run_test test_t15_ac1_already_queued_posts_one_thread_note
run_test test_t15_ac1_closed_posts_one_thread_note
run_test test_t15_ac1_note_uses_the_channel_and_ts_args_verbatim
run_test test_t15_ac1_dash_resolved_repo_gets_the_note_on_the_resolved_repo
run_test test_t15_ac2_repo_not_found_posts_no_comment
run_test test_t15_ac2_which_repo_posts_no_comment
run_test test_t15_args_two_arg_form_is_rejected
run_test test_t15_args_three_arg_form_is_rejected
run_test test_t15_ac6_prompt_documents_chat_id_and_message_id_as_args_3_and_4
