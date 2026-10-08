# Issue #133 — a developer BLOCKED / TEST DEFECT / IMPLEMENTED posted after TESTS WRITTEN stays the gate marker when the
# parallel pre-implementation `[test-reviewer] TESTS APPROVED` lands after it. Same definition in two places:
# supervisor.sh latest_marker and the snippet under "**Gate marker**" in agents/orchestrator.md.
#
#   AC1   gm_ac1_*        supervisor: latest_marker prints the BLOCKED; a tick holds (grace passed), no [queue-restart]
#   AC2   gm_ac2_*        BLOCKED + later DECISION: line 1 BLOCKED, line 2 decision; restart path; orchestrator.md rows unchanged
#   AC3   gm_ac3_*        TEST DEFECT in place of BLOCKED
#   AC4   gm_ac4_*        unchanged cases (characterisation: pass before and after)
#   AC5   gm_ac5_*        the three incident trails; orchestrator.md snippet and latest_marker agree on every fixture
#   AC6   gm_ac6_*        orchestrator.md TESTS APPROVED row points at the definition
#   AC7   (log line asserted by the AC1 tick test)
#   AC8   gm_ac8_*        no new mechanism: markers vocabulary and the rest of supervisor.sh untouched; only listed files changed
#
# Expected values are hand-written from the ticket. Every function/variable is prefixed gm_ / GM_. Placeholder repo names only.

HERE_GM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_GM=$(cd "$HERE_GM/../../.." && pwd)
SUP_GM="$HERE_GM/../supervisor.sh"
LIB_GM="$HERE_GM/../pipeline-lib.sh"
MARKERS_GM="$ROOT_GM/hooks/pipeline-markers.sh"
ORCH_GM="$ROOT_GM/agents/orchestrator.md"

GM_WRITTEN='**[test-writer] TESTS WRITTEN**'
GM_APPROVED='**[test-reviewer] TESTS APPROVED**'
GM_BLOCKED='**[fullstack-developer] BLOCKED**'
GM_DEFECT='**[fullstack-developer] TEST DEFECT**'
GM_IMPL='**[fullstack-developer] IMPLEMENTED**'
GM_DECISION=$'**[project-manager] DECISION**\nResolves: https://example.test/c/2'

# ------------------------------------------------------------------------------------------ helpers

gm_base() { (cd "$ROOT_GM" && git merge-base HEAD origin/main 2>/dev/null); }

gm_iso_ago() {
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

gm_fn() {  # gm_fn <file> <function> — prints the function body (top-level, closing brace in column 0)
  awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"
}

# gm_env — GM_PIPE, GM_HOME, GM_REPO, GM_GH (fake gh in an isolated HOME)
gm_env() {
  GM_PIPE=$(new_pipe); GM_HOME=$(new_home)
  GM_REPO="$GM_PIPE/repo-a"
  GM_GH="$GM_HOME/.local/bin"
  fixture_repo "$GM_REPO" "project-a/repo-a"
  mk_fake_gh "$GM_GH"
  echo "project-a/repo-a" > "$GM_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$GM_GH/claude"; chmod +x "$GM_GH/claude"   # never start a real run
}
gm_cleanup() { cleanup_running; rm -rf "$GM_PIPE" "$GM_HOME"; }

# gm_thread <body>... — writes comments (oldest -> newest, one minute apart) as the fake gh's comment list for every issue
gm_thread() {
  local arr='[]' b i=0
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "$(printf '2026-10-01T12:%02d:00Z' "$i")" '. + [{body: $b, createdAt: $t}]')
  done
  printf '%s' "$arr" > "$GM_GH/gh-issue-comments-json"
}

# gm_latest — latest_marker (extracted from supervisor.sh; sourcing it would run a tick) against the fake gh
gm_latest() {
  ( . "$MARKERS_GM"; . "$LIB_GM"
    eval "$(gm_fn "$SUP_GM" latest_marker)"
    PATH="$GM_GH:$PATH"; latest_marker "$GM_REPO" 42 )
}

# gm_snippet — runs the bash block under "**Gate marker**" in orchestrator.md with N=42, a `markers` function that reads
# the same fixture (same output shape as the real one: "<created_at> <login> <first line>") and a no-op `gh`.
# Prints the last non-empty output line.
gm_snippet() {
  local block
  block=$(awk '/^\*\*Gate marker\*\*/ {on=1; next} on && /^```bash/ {inb=1; next} on && inb && /^```/ {exit} on && inb {print}' "$ORCH_GM" \
    | sed 's/<N>/42/g')
  [ -n "$block" ] || { echo "NO-SNIPPET"; return 0; }
  ( . "$MARKERS_GM"
    markers() {
      jq -r --arg re "$(marker_re)" '.[] | (.body | split("\n")[0]) as $l | select($l | test($re)) | .createdAt + " jp " + $l' "$GM_GH/gh-issue-comments-json"
    }
    gh() { return 0; }
    eval "$block" 2>/dev/null | grep -v '^$' | tail -1 )
}

# gm_check <label> <expected line 1> [<expected line 2>] — latest_marker output, and the snippet's gate marker == line 1
gm_check() {
  local label=$1 want=$2 want2=${3:-} got snip expect="$2"
  [ -z "$want2" ] || expect="$2"$'\n'"$3"
  got=$(gm_latest)
  assert_eq "$got" "$expect" "$label: latest_marker" || return 1
  snip=$(gm_snippet)
  assert_contains "$snip" "$want" "$label: orchestrator.md snippet gate marker" || return 1
  if [ -n "$want2" ]; then assert_not_contains "$snip" "project-manager" "$label: snippet must not pick the decision" || return 1; fi
}

# ------------------------------------------------------------------------------------------ AC1

test_gm_ac1_latest_marker_prints_the_developer_blocked() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_BLOCKED" "$GM_APPROVED"
  gm_check "AC1" "$GM_BLOCKED"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac1_tick_holds_for_jp_and_does_not_restart() {
  gm_env
  mk_restarting "$GM_PIPE" 42 "$GM_REPO"
  gm_iso_ago 1300 > "$GM_PIPE/orch-42.start"   # past GRACE_PERIOD_SECS
  gm_thread "$GM_WRITTEN" "$GM_BLOCKED" "$GM_APPROVED"
  HOME="$GM_HOME" PATH="$GM_GH:/usr/bin:/bin" PIPE="$GM_PIPE" QUEUE="$GM_PIPE/queue" LOGDIR="$GM_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_GM" >/dev/null 2>&1
  local held log queued
  held=$([ -e "$GM_PIPE/orch-42.held" ] && echo present || echo absent)
  queued=$([ -e "$GM_PIPE/queue/orch-42.json" ] && echo present || echo absent)
  log=$(cat "$GM_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  gm_cleanup
  assert_eq "$held" "present" "AC1: .held" || return 1
  assert_eq "$queued" "absent" "AC1: nothing queued" || return 1
  assert_contains "$log" "[held] #42 — waiting on JP: **[fullstack-developer] BLOCKED**" "AC1: held log line" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "AC1: no queue-restart line" || return 1
}

# ------------------------------------------------------------------------------------------ AC2

test_gm_ac2_blocked_then_approved_then_decision_prints_blocked_and_decision() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_BLOCKED" "$GM_APPROVED" "$GM_DECISION"
  gm_check "AC2" "$GM_BLOCKED" "**[project-manager] DECISION**"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac2_tick_with_decision_takes_the_restart_path() {
  gm_env
  mk_restarting "$GM_PIPE" 42 "$GM_REPO"
  gm_iso_ago 1300 > "$GM_PIPE/orch-42.start"
  gm_thread "$GM_WRITTEN" "$GM_BLOCKED" "$GM_APPROVED" "$GM_DECISION"
  HOME="$GM_HOME" PATH="$GM_GH:/usr/bin:/bin" PIPE="$GM_PIPE" QUEUE="$GM_PIPE/queue" LOGDIR="$GM_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_GM" >/dev/null 2>&1
  local held log
  held=$([ -e "$GM_PIPE/orch-42.held" ] && echo present || echo absent)
  log=$(cat "$GM_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  gm_cleanup
  assert_eq "$held" "absent" "AC2: not held" || return 1
  assert_contains "$log" "[queue-restart] #42" "AC2: restart path" || return 1
}

test_gm_ac2_orchestrator_resume_rows_still_present() {   # characterisation: rows keyed on the BLOCKED gate marker are untouched
  grep -qF 'whose line 2 is `Resolves: <URL of that BLOCKED comment>`' "$ORCH_GM" || { fail "resume row text missing"; return 1; }
  grep -qF 'first line is exactly `go` / `GO` / `**[jp] GO**`' "$ORCH_GM" || { fail "JP exact-form go clause missing"; return 1; }
  grep -qF 'where a private artefact is stored / who gets access' "$ORCH_GM" || { fail "JP-only carve-out missing"; return 1; }
}

# ------------------------------------------------------------------------------------------ AC3

test_gm_ac3_test_defect_is_the_gate_marker() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_DEFECT" "$GM_APPROVED"
  gm_check "AC3" "$GM_DEFECT"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac3_implemented_is_the_gate_marker() {   # ticket's definition names IMPLEMENTED too
  gm_env; gm_thread "$GM_WRITTEN" "$GM_IMPL" "$GM_APPROVED"
  gm_check "AC3 IMPLEMENTED" "$GM_IMPL"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac3_latest_developer_marker_wins() {   # "the latest such"
  gm_env; gm_thread "$GM_WRITTEN" "$GM_DEFECT" "$GM_BLOCKED" "$GM_APPROVED"
  gm_check "AC3 latest" "$GM_BLOCKED"; local rc=$?
  gm_cleanup; return $rc
}

# ------------------------------------------------------------------------------------------ AC4 (characterisation)

test_gm_ac4_approved_without_developer_marker() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_APPROVED"
  gm_check "AC4a" "$GM_APPROVED"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac4_blocked_after_approved_is_the_gate_marker() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_APPROVED" "$GM_BLOCKED"
  gm_check "AC4b" "$GM_BLOCKED"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac4_blocked_before_a_newer_tests_written_does_not_count() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_BLOCKED" "$GM_WRITTEN" "$GM_APPROVED"
  gm_check "AC4c" "$GM_APPROVED"; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac4_tests_fail_after_blocked_stays_tests_fail() {
  gm_env; gm_thread "$GM_WRITTEN" "$GM_BLOCKED" '**[test-reviewer] TESTS FAIL: 2 findings**'
  gm_check "AC4d" '**[test-reviewer] TESTS FAIL: 2 findings**'; local rc=$?
  gm_cleanup; return $rc
}

test_gm_ac4_post_implementation_review_markers_are_never_affected() {
  local m rc=0
  for m in '**[test-reviewer] PASS**' '**[test-reviewer] FAIL: 1 findings**'; do
    gm_env; gm_thread "$GM_WRITTEN" "$GM_APPROVED" "$GM_IMPL" "$m"
    gm_check "AC4e [$m]" "$m" || rc=1
    gm_cleanup
    [ "$rc" = 0 ] || return 1
  done
}

# ------------------------------------------------------------------------------------------ AC5 (incident fixtures)

test_gm_ac5_incident_trails_yield_blocked_from_both_places() {
  local t rc=0 n
  for n in 1061 447 419; do
    gm_env
    case "$n" in   # trails from the ticket: TESTS WRITTEN -> BLOCKED -> TESTS APPROVED
      1061) t='12:45:56 12:46:38 12:47:40' ;;
      447)  t='09:25:53 09:27:12 09:30:46' ;;
      419)  t='13:16:55 13:17:25 13:17:37' ;;
    esac
    set -- $t
    jq -n --arg a "$GM_WRITTEN" --arg b "$GM_BLOCKED" --arg c "$GM_APPROVED" --arg t1 "2026-10-01T$1Z" --arg t2 "2026-10-01T$2Z" --arg t3 "2026-10-01T$3Z" \
      '[{body:$a,createdAt:$t1},{body:$b,createdAt:$t2},{body:$c,createdAt:$t3}]' > "$GM_GH/gh-issue-comments-json"
    gm_check "AC5 #$n" "$GM_BLOCKED" || rc=1
    gm_cleanup
    [ "$rc" = 0 ] || return 1
  done
}

# ------------------------------------------------------------------------------------------ AC6

test_gm_ac6_tests_approved_row_points_at_the_definition() {
  local row
  row=$(grep -F '| `[test-reviewer] TESTS APPROVED` |' "$ORCH_GM")
  [ -n "$row" ] || { fail "TESTS APPROVED row not found"; return 1; }
  assert_not_contains "$row" "continue polling the developer" "AC6: old wording gone" || return 1
  printf '%s' "$row" | grep -qi 'gate marker' || { fail "AC6: row must point to the gate-marker definition: $row"; return 1; }
}

test_gm_ac6_definition_names_the_exception_once() {
  local para n
  para=$(awk '/^\*\*Gate marker\*\*/ {on=1} on && /^```/ {c++} on {print} on && c>=2 {exit}' "$ORCH_GM")
  assert_contains "$para" "[test-reviewer] TESTS APPROVED" "AC6: definition names TESTS APPROVED" || return 1
  assert_contains "$para" "[fullstack-developer]" "AC6: definition names the developer" || return 1
  assert_contains "$para" "TESTS WRITTEN" "AC6: definition anchors on the latest TESTS WRITTEN" || return 1
  assert_contains "$para" "TEST DEFECT" "AC6: definition names TEST DEFECT" || return 1
  n=$(grep -c 'The approval answers the tests, not the developer' "$ORCH_GM")
  assert_eq "$n" "1" "AC6: exactly one statement of the rule (no second rule beside it)" || return 1
}

# ------------------------------------------------------------------------------------------ AC8

test_gm_ac8_no_new_mechanism() {
  local base now was extra
  base=$(gm_base); [ -n "$base" ] || { fail "AC8: no merge-base with origin/main"; return 1; }
  # vocabulary untouched
  # #114: the only allowed diff is the `intake)` case line and the ` intake` token in marker_re's agent list
  extra=$(cd "$ROOT_GM" && git diff -U0 "$base" -- hooks/pipeline-markers.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' \
    | grep -vE '^\+ *intake\) +echo ' | grep -vE '^[-+] +infra-planner infra-reviewer infra-operator jp project-manager( intake)?; do ' || true)
  assert_eq "$extra" "" "AC8: hooks/pipeline-markers.sh changed beyond #114's intake line + token" || return 1
  # supervisor.sh: everything except latest_marker is byte-identical
  # #114: also skip exactly the intake additions: the 3b step block (to its first blank line), its header-comment line, and step 5's one-line skip
  now=$(awk '/^latest_marker\(\) \{/ {skip=1} !skip {print} skip && /^}/ {skip=0}' "$SUP_GM" | sed -e '/^# 3b\. Intake/,/^$/d' -e '/^#   3b\. intake: /d' -e '/an intake run (3b) owns it/d' | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)
  was=$(cd "$ROOT_GM" && git show "$base:skills/orchestrate/supervisor.sh" | awk '/^latest_marker\(\) \{/ {skip=1} !skip {print} skip && /^}/ {skip=0}' | sed -e '/^# 3b\. Intake/,/^$/d' -e '/^#   3b\. intake: /d' -e '/an intake run (3b) owns it/d' | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)
  assert_eq "$now" "$was" "AC8: supervisor.sh outside latest_marker" || return 1
  # only the ticket's files (plus tests) changed
  extra=$(cd "$ROOT_GM" && git diff --name-only "$base" | grep -vE '^(agents/orchestrator\.md|skills/orchestrate/supervisor\.sh|skills/orchestrate/pipeline-lib\.sh|hooks/sync-agents\.sh|hooks/no-duplicate-stage\.sh|skills/orchestrate/tests/)' | grep -vxE 'agents/intake\.md|agents/README\.md|README\.md|hooks/pipeline-markers\.sh|hooks/require-handoff-marker\.sh|skills/orchestrate/(intake-labels|scan-backlog|config|pipeline-lib)\.sh' || true)   # #114: exactly its Files-table paths
  assert_eq "$extra" "" "AC8: files changed outside the ticket's list" || return 1
}

run_test test_gm_ac1_latest_marker_prints_the_developer_blocked
run_test test_gm_ac1_tick_holds_for_jp_and_does_not_restart
run_test test_gm_ac2_blocked_then_approved_then_decision_prints_blocked_and_decision
run_test test_gm_ac2_tick_with_decision_takes_the_restart_path
run_test test_gm_ac2_orchestrator_resume_rows_still_present
run_test test_gm_ac3_test_defect_is_the_gate_marker
run_test test_gm_ac3_implemented_is_the_gate_marker
run_test test_gm_ac3_latest_developer_marker_wins
run_test test_gm_ac4_approved_without_developer_marker
run_test test_gm_ac4_blocked_after_approved_is_the_gate_marker
run_test test_gm_ac4_blocked_before_a_newer_tests_written_does_not_count
run_test test_gm_ac4_tests_fail_after_blocked_stays_tests_fail
run_test test_gm_ac4_post_implementation_review_markers_are_never_affected
run_test test_gm_ac5_incident_trails_yield_blocked_from_both_places
run_test test_gm_ac6_tests_approved_row_points_at_the_definition
run_test test_gm_ac6_definition_names_the_exception_once
run_test test_gm_ac8_no_new_mechanism
