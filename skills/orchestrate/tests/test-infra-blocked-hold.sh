# Issue #41 — an infra ticket waiting on an open `Blocked by:` dependency must park once (the
# infra-operator posts `**[infra-operator] BLOCKED**` with a dependency-hold template) instead of the
# orchestrator reporting it in prose and exiting, which left the last marker at `PLAN PASS` and made
# the supervisor relaunch it forever.
#
#   AC1a-e  doc contract: infra-operator owns the blocker check; orchestrator no longer checks it
#   AC2     doc contract: a routing row lets a dependency-held ticket resume once the dependency closes
#   AC3a/b  supervisor behaviour the fix relies on (characterisation: passes before AND after —
#           supervisor.sh is deliberately not edited, do not change it to make these "fail first")
#   AC4     README infra-track paragraph
#   AC5     supervisor.sh and tests/lib untouched (diff against the merge-base with origin/main)
#
# Doc-contract cases read tracked files only (fixed-string grep, per test-followup-rules-docs.sh).
# Supervisor cases run one tick in an isolated HOME + PIPE + QUEUE + LOGDIR with the fake gh.
# Every function/variable here is prefixed ib_ / IB_ (all test files share one shell).
# Placeholder repo names only.

HERE_IB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_IB=$(cd "$HERE_IB/../../.." && pwd)
SUP_IB="$HERE_IB/../supervisor.sh"
OP_IB="$ROOT_IB/agents/infra-operator.md"
ORCH_IB="$ROOT_IB/agents/orchestrator.md"
README_IB="$ROOT_IB/README.md"

IB_BLOCKED='**[infra-operator] BLOCKED**'
IB_PLAN_PASS='**[infra-reviewer] PLAN PASS**'

# ib_has <file> <fixed-string>
ib_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }

# ib_text_has <label> <text> <fixed-string>
ib_text_has() { printf '%s\n' "$2" | grep -qF -- "$3" || { fail "$1: missing [$3] in:
$2"; return 1; }; }

# ib_text_has_i <label> <text> <regex, case-insensitive>
ib_text_has_i() { printf '%s\n' "$2" | grep -qiE -- "$3" || { fail "$1: missing (any case, regex) [$3] in:
$2"; return 1; }; }

# ib_text_lacks <label> <text> <fixed-string>
ib_text_lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1: must NOT contain [$3] in:
$2"; return 1; fi; }

# ib_section <file> <heading-prefix> — lines after the heading up to the next "## " heading
ib_section() { awk -v h="$2" 'index($0, h) == 1 { on = 1; next } on && /^## / { exit } on { print }' "$1"; }

# ib_fenced_block_with <file> <fixed-string> — the first ``` fenced block containing <fixed-string>
ib_fenced_block_with() {
  awk -v needle="$2" '
    /^```/ { if (inb) { if (index(blk, needle)) { printf "%s", blk; exit } inb = 0; blk = "" } else { inb = 1; blk = "" } next }
    inb { blk = blk $0 "\n" }
  ' "$1"
}

# ---------------------------------------------------------------------------------------- AC1

test_ib_ac1a_operator_preflight_posts_blocked_when_dependency_open() {
  local pre bullet
  ib_has "$OP_IB" 'Held: blocked by' || return 1
  pre=$(awk '/^1\. \*\*Pre-flight\.\*\*/ { on = 1; next } on && /^2\. \*\*For each step/ { exit } on { print }' "$OP_IB")
  assert_ne "$pre" "" "AC1a: infra-operator.md has a Pre-flight block" || return 1
  bullet=$(printf '%s\n' "$pre" | grep -F 'Blocked by:' | head -1)
  assert_ne "$bullet" "" "AC1a: the Pre-flight block has a bullet naming \`Blocked by:\`" || return 1
  ib_text_has "AC1a: pre-flight Blocked-by bullet" "$bullet" 'BLOCKED' || return 1
  ib_text_has_i "AC1a: the operator stops (runs no step)" "$pre" 'stop' || return 1
}

test_ib_ac1b_dependency_hold_template_under_handoff_comments() {
  local sec blk first
  sec=$(ib_section "$OP_IB" '## Handoff comments')
  assert_ne "$sec" "" "AC1b: infra-operator.md has a Handoff comments section" || return 1
  ib_text_has "AC1b: handoff section" "$sec" 'Held: blocked by' || return 1
  ib_text_has "AC1b: handoff section" "$sec" 'No step was run.' || return 1
  blk=$(ib_fenced_block_with "$OP_IB" 'Held: blocked by')
  assert_ne "$blk" "" "AC1b: a fenced template block contains the Held: blocked by line" || return 1
  first=$(printf '%s\n' "$blk" | head -1)
  assert_eq "$first" "$IB_BLOCKED" "AC1b: template line 1 is the BLOCKED marker" || return 1
  ib_text_has "AC1b: template" "$blk" 'Held: blocked by #M[, #K] — still open' || return 1
  ib_text_has "AC1b: template" "$blk" 'Runbook: <PLAN READY comment URL>' || return 1
  ib_text_has "AC1b: template" "$blk" 'No step was run. Close the issue(s) above, then relaunch this ticket (or re-add `agent-go`).' || return 1
}

test_ib_ac1c_orchestrator_first_dispatch_row_no_longer_checks_blocked_by() {
  local row n
  n=$(grep -cF '| infra-operator (first) |' "$ORCH_IB")
  assert_eq "$n" "1" "AC1c: exactly one \`| infra-operator (first) |\` row" || return 1
  row=$(grep -F '| infra-operator (first) |' "$ORCH_IB")
  ib_text_has "AC1c: infra-operator (first) row" "$row" 'PLAN PASS' || return 1
  ib_text_lacks "AC1c: infra-operator (first) row" "$row" 'Blocked by' || return 1
}

test_ib_ac1d_blocked_by_paragraph_names_the_operator_as_enforcer() {
  local line
  line=$(grep -F '`Blocked by:` gates only the operator' "$ORCH_IB" | head -1)
  assert_ne "$line" "" "AC1d: the \`Blocked by:\` gates only the operator paragraph still exists" || return 1
  ib_text_has "AC1d: Blocked-by paragraph" "$line" 'infra-operator' || return 1
  ib_text_has "AC1d: Blocked-by paragraph" "$line" 'BLOCKED' || return 1
}

test_ib_ac1e_plan_pass_still_dispatches_the_operator() {
  local row
  row=$(grep -F '| `[infra-reviewer] PLAN PASS` |' "$ORCH_IB" | head -1)
  assert_ne "$row" "" "AC1e: the PLAN PASS routing row exists" || return 1
  ib_text_has "AC1e: PLAN PASS row" "$row" 'Dispatch **infra-operator**' || return 1
}

# ---------------------------------------------------------------------------------------- AC2

test_ib_ac2_routing_row_resumes_a_dependency_held_ticket() {
  local tbl resume generic
  tbl=$(awk '/^### Infra track/ { on = 1; next } on && /^Infra-track pre-dispatch validation/ { exit } on { print }' "$ORCH_IB")
  assert_ne "$tbl" "" "AC2: orchestrator.md has an Infra track routing table" || return 1
  # a table row (starts with "|") carrying all three literals
  resume=$(printf '%s\n' "$tbl" | grep '^|' | grep -F '[infra-operator] BLOCKED' | grep -F 'Held: blocked by' | grep -F 'infra-operator**' | head -1)
  assert_ne "$resume" "" "AC2: a routing-table row names [infra-operator] BLOCKED, Held: blocked by, and infra-operator**" || return 1
  ib_text_has "AC2: resume row checks each named issue's state" "$resume" '--json state' || return 1
  ib_text_has_i "AC2: resume row has a terminal branch when one is still open" "$resume" 'terminal' || return 1
  ib_text_has_i "AC2: resume row reports the open issue(s) to JP" "$resume" 'JP' || return 1
  # the generic BLOCKED row remains (a different row) for every other BLOCKED
  generic=$(printf '%s\n' "$tbl" | grep '^|' | grep -F '[infra-planner] BLOCKED' | grep -F '[infra-reviewer] BLOCKED' | head -1)
  assert_ne "$generic" "" "AC2: the generic infra BLOCKED row remains" || return 1
  ib_text_has "AC2: generic BLOCKED row" "$generic" 'Terminal: report to JP verbatim' || return 1
  ib_text_lacks "AC2: generic BLOCKED row is not the resume row" "$generic" 'Held: blocked by' || return 1
}

# ---------------------------------------------------------------------------------------- AC3

# ib_env — sets IB_PIPE, IB_HOME, IB_REPO, IB_GH
ib_env() {
  IB_PIPE=$(new_pipe); IB_HOME=$(new_home)
  IB_REPO="$IB_PIPE/repo-a"
  IB_GH="$IB_HOME/.local/bin"
  fixture_repo "$IB_REPO" "project-a/repo-a"
  mk_fake_gh "$IB_GH"
  echo "project-a/repo-a" > "$IB_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$IB_GH/claude"; chmod +x "$IB_GH/claude"   # never start a real run
}

ib_cleanup() { cleanup_running; rm -rf "$IB_PIPE" "$IB_HOME"; }

ib_tick() {  # one run of supervisor.sh in the isolated env
  HOME="$IB_HOME" PATH="$IB_GH:/usr/bin:/bin" PIPE="$IB_PIPE" QUEUE="$IB_PIPE/queue" LOGDIR="$IB_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_IB" >/dev/null 2>&1
}

ib_log() { cat "$IB_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

ib_iso_ago() {  # ib_iso_ago <secs> -> ISO-8601 UTC timestamp <secs> ago
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

ib_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

# ib_fixture <marker> — issue 42, exited, no queue entry, .start 1300 s old (past GRACE_PERIOD_SECS=1200)
ib_fixture() {
  ib_env
  mk_restarting "$IB_PIPE" 42 "$IB_REPO"
  ib_iso_ago 1300 > "$IB_PIPE/orch-42.start"
  printf '%s\n' "$1" > "$IB_GH/gh-issue-latest-marker"
}

test_ib_ac3a_operator_blocked_parks_the_run_without_a_restart() {
  ib_fixture "$IB_BLOCKED"
  ib_tick
  local held alert restarts queued log
  held=$(ib_present "$IB_PIPE/orch-42.held"); restarts=$(ib_present "$IB_PIPE/orch-42.restarts")
  queued=$(ib_present "$IB_PIPE/queue/orch-42.json")
  alert=$(cat "$IB_PIPE/orch-42.alert" 2>/dev/null); log=$(ib_log)
  ib_cleanup
  assert_eq "$held" "present" "AC3a: [infra-operator] BLOCKED parks the run (.held)" || return 1
  assert_contains "$alert" "waiting on JP" "AC3a: alert says waiting on JP" || return 1
  assert_contains "$log" "[held] #42" "AC3a: [held] logged" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "AC3a: no restart logged" || return 1
  assert_eq "$restarts" "absent" "AC3a: no restart state" || return 1
  assert_eq "$queued" "absent" "AC3a: nothing queued" || return 1
}

test_ib_ac3b_plan_pass_is_not_terminal() {
  ib_fixture "$IB_PLAN_PASS"
  ib_tick
  local held log
  held=$(ib_present "$IB_PIPE/orch-42.held"); log=$(ib_log)
  ib_cleanup
  assert_eq "$held" "absent" "AC3b: PLAN PASS does not park the run" || return 1
  assert_not_contains "$log" "[held] #42" "AC3b: no [held] line for PLAN PASS" || return 1
  # control: the tick did act on #42 (the relaunch the incident showed), so absence of [held] is not vacuous
  assert_contains "$log" "[queue-restart] #42" "AC3b control: PLAN PASS is still treated as a live, unfinished ticket" || return 1
}

# ---------------------------------------------------------------------------------------- AC4

test_ib_ac4_readme_infra_track_says_operator_posts_blocked_on_open_dependency() {
  local para
  para=$(grep -F '**Infra track.**' "$README_IB" | head -1)
  assert_ne "$para" "" "AC4: README has the **Infra track.** paragraph" || return 1
  ib_text_has "AC4: Infra track paragraph" "$para" 'Blocked by:' || return 1
  ib_text_has "AC4: Infra track paragraph" "$para" 'BLOCKED' || return 1
  ib_text_has_i "AC4: Infra track paragraph says the dependency is open" "$para" 'open' || return 1
}

# ---------------------------------------------------------------------------------------- AC5

# Characterisation: passes now and must keep passing. Diff is against the merge-base with origin/main
# so it stays correct after main moves; skipped (with a note) where there is no git history to compare.
test_ib_ac5_supervisor_and_test_lib_are_not_edited() {
  local base diff
  base=$(cd "$ROOT_IB" && git merge-base HEAD origin/main 2>/dev/null)
  if [ -z "$base" ]; then
    printf '    (AC5 skipped: no origin/main merge-base in this checkout)\n' >&2
    return 0
  fi
  diff=$(cd "$ROOT_IB" && git diff --stat "$base" -- skills/orchestrate/supervisor.sh skills/orchestrate/tests/lib)
  assert_eq "$diff" "" "AC5: no change to supervisor.sh or tests/lib" || return 1
}

run_test test_ib_ac1a_operator_preflight_posts_blocked_when_dependency_open
run_test test_ib_ac1b_dependency_hold_template_under_handoff_comments
run_test test_ib_ac1c_orchestrator_first_dispatch_row_no_longer_checks_blocked_by
run_test test_ib_ac1d_blocked_by_paragraph_names_the_operator_as_enforcer
run_test test_ib_ac1e_plan_pass_still_dispatches_the_operator
run_test test_ib_ac2_routing_row_resumes_a_dependency_held_ticket
run_test test_ib_ac3a_operator_blocked_parks_the_run_without_a_restart
run_test test_ib_ac3b_plan_pass_is_not_terminal
run_test test_ib_ac4_readme_infra_track_says_operator_posts_blocked_on_open_dependency
run_test test_ib_ac5_supervisor_and_test_lib_are_not_edited
