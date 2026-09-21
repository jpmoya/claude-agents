# Handoff hook + orchestrator marker reads over REST (claude-agents#57) — regression guard.
# On 2026-09-20 the shared GraphQL budget ran out: hooks/require-handoff-marker.sh read markers with
# `gh issue view --json comments` (GraphQL) and ended in `|| exit 0` *above* the nag-file write, so a
# rate-limited but working stage left no liveness signal and the orchestrator killed it as stuck.
# These cases run the shipped hook, and the count()/markers() functions extracted from
# agents/orchestrator.md, against a fake `gh` that behaves like the real one under --paginate:
# the --jq filter is applied to each page SEPARATELY and the outputs are concatenated.
# Nothing here touches /tmp/pipeline: PIPE, the fake gh and the page fixtures live in a mktemp -d.

HERE_HR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS_HR="$HERE_HR/../../../hooks"
HOOK_HR="$HOOKS_HR/require-handoff-marker.sh"
ORCH_MD_HR="$HERE_HR/../../../agents/orchestrator.md"

# hr_setup — fresh sandbox in HR_DIR: bin/gh (fake), pages/ (fixtures), pipe/ (PIPE), gh-args.log.
# The fake gh only knows `gh api <path> ... --jq <expr>`; anything else (e.g. `gh issue view`) exits 1.
# Knob: a file $HR_DIR/gh-fail makes every call exit 1 (a rate-limited / unreachable API).
hr_setup() {
  HR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-hook-rest.XXXXXX")
  mkdir -p "$HR_DIR/bin" "$HR_DIR/pages" "$HR_DIR/pipe"
  cat > "$HR_DIR/bin/gh" <<EOF
#!/bin/bash
D="$HR_DIR"
printf '%s\n' "\$*" >> "\$D/gh-args.log"
[ -e "\$D/gh-fail" ] && { echo "HTTP 403: API rate limit exceeded" >&2; exit 1; }
[ "\$1" = "api" ] || { echo "fake gh: unsupported: \$*" >&2; exit 1; }
expr=""
while [ \$# -gt 0 ]; do
  case "\$1" in --jq) expr=\$2; shift ;; esac
  shift
done
[ -n "\$expr" ] || exit 1
for p in "\$D"/pages/page*.json; do
  [ -e "\$p" ] || continue
  jq -r "\$expr" "\$p" || exit 1
done
exit 0
EOF
  chmod +x "$HR_DIR/bin/gh"
}

hr_teardown() { rm -rf "$HR_DIR"; }

# hr_comment <created_at> <login> <body> — one REST-shaped issue comment object
hr_comment() { jq -n --arg t "$1" --arg u "$2" --arg b "$3" '{created_at:$t, user:{login:$u}, body:$b}'; }

# Two-page fixture: page 1 = PM marker, a deployer NOTE, deployer marker #1; page 2 = an
# off-vocabulary deployer line, deployer marker #2. Deployer routing markers: 2. All markers: 3.
hr_pages_two() {
  { hr_comment 2026-09-20T23:00:00Z jpmoya '**[product-manager] READY FOR ENGINEERING**
Lane: fast'
    hr_comment 2026-09-20T23:05:00Z jpmoya '**[deployer] NOTE**
still waiting on the staging deploy'
    hr_comment 2026-09-20T23:10:00Z jpmoya '**[deployer] BLOCKED**
staging deploy stuck'
  } | jq -s . > "$HR_DIR/pages/page1.json"
  { hr_comment 2026-09-20T23:20:00Z jpmoya '**[deployer] COMPLETED**
invented status'
    hr_comment 2026-09-20T23:30:00Z jpmoya '**[deployer] DEPLOYED**
PR #1 merged'
  } | jq -s . > "$HR_DIR/pages/page2.json"
}

# Single page holding only an off-vocabulary deployer line: zero routing markers.
hr_pages_offvocab() {
  hr_comment 2026-09-20T23:20:00Z jpmoya '**[deployer] COMPLETED**
invented status' | jq -s . > "$HR_DIR/pages/page1.json"
}

# AC8 fixture: page 1 = one NOTE and marker #1, page 2 = marker #2 (a different agent's).
hr_pages_markers() {
  { hr_comment 2026-09-20T23:05:00Z jpmoya '**[deployer] NOTE**
still waiting on the staging deploy'
    hr_comment 2026-09-20T23:10:00Z jpmoya '**[code-reviewer] PASS**
review body'
  } | jq -s . > "$HR_DIR/pages/page1.json"
  hr_comment 2026-09-20T23:30:00Z deploy-bot '**[deployer] DEPLOYED**
PR #1 merged' | jq -s . > "$HR_DIR/pages/page2.json"
}

# hr_run_hook <before> — runs the shipped hook for deployer on issue 600. Sets HR_RC / HR_ERR.
HR_NAG_REL="pipe/600-deployer-nags.txt"
hr_run_hook() {
  printf '%s\n' "$1" > "$HR_DIR/pipe/600-deployer-before.txt"
  HR_ERR=$( PATH="$HR_DIR/bin:$PATH" PIPE="$HR_DIR/pipe" PIPELINE_ISSUE=600 PIPELINE_AGENT=deployer \
    PIPELINE_REPO=Benjis-Plants/scheduler bash "$HOOK_HR" </dev/null 2>&1 >/dev/null ); HR_RC=$?
}

# hr_orch_fn <name> <args...> — extracts shell function <name> from orchestrator.md and runs it with
# the fake gh first on PATH and the repo's pipeline-markers.sh sourced. Sets HR_OUT / HR_RC.
hr_orch_fn() {
  local name=$1; shift
  sed -n "/^$name() {/,/^}/p" "$ORCH_MD_HR" > "$HR_DIR/fn.sh"
  HR_OUT=$( PATH="$HR_DIR/bin:$PATH"; . "$HOOKS_HR/pipeline-markers.sh"; . "$HR_DIR/fn.sh"; "$name" "$@" 2>/dev/null ); HR_RC=$?
}

# --- AC1 / AC5 / AC6 / AC9: static pins -------------------------------------------------------

test_hr_hook_has_no_graphql_read_or_post() {
  local n
  n=$(grep -c 'gh issue view' "$HOOK_HR"); assert_eq "$n" "0" "AC1: hook must not call gh issue view (GraphQL)" || return 1
  n=$(grep -c 'gh issue comment' "$HOOK_HR"); assert_eq "$n" "0" "AC5: hook must not mention gh issue comment" || return 1
  n=$(grep -c '^PIPE="${PIPE:-/tmp/pipeline}"$' "$HOOK_HR"); assert_eq "$n" "1" "AC6: PIPE must be overridable, same form as config.sh" || return 1
}

test_hr_orchestrator_has_no_graphql_marker_read() {
  local n
  n=$(grep -c 'gh issue view "\$1" --json comments' "$ORCH_MD_HR")
  assert_eq "$n" "0" "AC9: markers()/count() must not read comments via gh issue view" || return 1
}

# --- AC1 + AC2: REST endpoint, one integer across pages ---------------------------------------

test_hr_two_pages_new_marker_lets_stage_stop() {
  hr_setup; hr_pages_two
  echo 1 > "$HR_DIR/$HR_NAG_REL"
  hr_run_hook 1
  local args; args=$(cat "$HR_DIR/gh-args.log" 2>/dev/null)
  local rc=0
  assert_eq "$HR_RC" "0" "AC2: 2 markers across 2 pages > BEFORE=1 → exit 0" \
    && assert_eq "$HR_ERR" "" "AC2: nothing on stderr (a per-page count would break the -gt test)" \
    && assert_file_absent "$HR_DIR/$HR_NAG_REL" "AC2: nag file removed once the marker is seen" \
    && assert_contains "$args" "api repos/Benjis-Plants/scheduler/issues/600/comments?per_page=100" "AC1: REST comments endpoint" \
    && assert_contains "$args" "--paginate" "AC1: paginated read" \
    && assert_not_contains "$args" "--slurp" "AC2: gh rejects --slurp with --jq" || rc=1
  hr_teardown; return $rc
}

test_hr_two_pages_no_new_marker_nags() {
  hr_setup; hr_pages_two
  hr_run_hook 2
  local rc=0
  assert_eq "$HR_RC" "2" "AC2: 2 markers, BEFORE=2 → refuse the stop" \
    && assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "1" "AC2: nag file reads 1" || rc=1
  hr_teardown; return $rc
}

# --- AC3 + AC6: zero markers / off-vocabulary line is a normal nag, not a read error ----------

test_hr_zero_markers_is_not_an_error() {
  hr_setup; hr_pages_offvocab
  hr_run_hook 0
  local rc=0
  assert_eq "$HR_RC" "2" "AC3/AC6: **[deployer] COMPLETED** does not count → nag" \
    && assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "1" "AC3: nag file incremented from absent to 1" || rc=1
  hr_teardown; return $rc
}

# --- AC4: a failed read exits 0 but still moves the liveness signal ---------------------------

test_hr_read_failure_creates_nag_file_with_zero() {
  hr_setup; hr_pages_two; : > "$HR_DIR/gh-fail"
  hr_run_hook 1
  local rc=0
  assert_eq "$HR_RC" "0" "AC4: read failure fails open" \
    && assert_file_exists "$HR_DIR/$HR_NAG_REL" "AC4: nag file must exist after a failed read (liveness signal)" \
    && assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "0" "AC4: a read error must not consume a nag" || rc=1
  hr_teardown; return $rc
}

test_hr_read_failure_advances_mtime_keeps_count() {
  hr_setup; hr_pages_two; : > "$HR_DIR/gh-fail"
  echo 1 > "$HR_DIR/$HR_NAG_REL"
  touch -t 202001010000 "$HR_DIR/$HR_NAG_REL"
  touch -t 202006010000 "$HR_DIR/ref"
  hr_run_hook 1
  local rc=0 newer=no
  [ "$HR_DIR/$HR_NAG_REL" -nt "$HR_DIR/ref" ] && newer=yes
  assert_eq "$HR_RC" "0" "AC4: read failure fails open" \
    && assert_eq "$newer" "yes" "AC4: nag file mtime must advance on a failed read" \
    && assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "1" "AC4: nag count unchanged by a failed read" || rc=1
  hr_teardown; return $rc
}

# --- AC5: nag message posts over REST, rest of the wording unchanged ---------------------------

test_hr_nag_message_posts_over_rest() {
  hr_setup; hr_pages_two
  hr_run_hook 2
  local rc=0
  assert_contains "$HR_ERR" "gh api repos/Benjis-Plants/scheduler/issues/600/comments -F body=@" "AC5: REST post instruction" \
    && assert_not_contains "$HR_ERR" "gh issue comment" "AC5: no GraphQL post instruction" \
    && assert_contains "$HR_ERR" "the only routing markers deployer has are: DEPLOYED, BLOCKED." "AC5: valid-marker list unchanged" \
    && assert_contains "$HR_ERR" "keep working and wait for it — post nothing yet" "AC5: keep-working wording unchanged" \
    && assert_contains "$HR_ERR" "Use BLOCKED, with the exact reason underneath, only if you could not finish. Then stop." "AC5: BLOCKED guidance unchanged" || rc=1
  hr_teardown; return $rc
}

# --- AC6: 2-nag bound, missing before-file, env guard ------------------------------------------

test_hr_two_nag_bound() {
  hr_setup; hr_pages_two
  local rc=0
  hr_run_hook 2; assert_eq "$HR_RC" "2" "AC6: first refusal" || rc=1
  hr_run_hook 2; assert_eq "$HR_RC" "2" "AC6: second refusal" || rc=1
  assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "2" "AC6: nag file reads 2 after two refusals" || rc=1
  hr_run_hook 2; assert_eq "$HR_RC" "0" "AC6: third stop is let through" || rc=1
  assert_eq "$(cat "$HR_DIR/$HR_NAG_REL" 2>/dev/null)" "2" "AC6: bound reached, count stays 2" || rc=1
  hr_teardown; return $rc
}

test_hr_inert_without_before_file_or_env() {
  hr_setup; hr_pages_two
  local rc=0 out
  PATH="$HR_DIR/bin:$PATH" PIPE="$HR_DIR/pipe" PIPELINE_ISSUE=600 PIPELINE_AGENT=deployer \
    PIPELINE_REPO=Benjis-Plants/scheduler bash "$HOOK_HR" </dev/null >/dev/null 2>&1
  assert_eq "$?" "0" "AC6: no before-file → exit 0" || rc=1
  echo 2 > "$HR_DIR/pipe/600-deployer-before.txt"
  ( unset PIPELINE_ISSUE PIPELINE_AGENT PIPELINE_REPO
    PATH="$HR_DIR/bin:$PATH" PIPE="$HR_DIR/pipe" bash "$HOOK_HR" </dev/null >/dev/null 2>&1 )
  assert_eq "$?" "0" "AC6: no stage coordinates → exit 0" || rc=1
  assert_file_absent "$HR_DIR/gh-args.log" "AC6: an inert hook never calls gh" || rc=1
  assert_file_absent "$HR_DIR/$HR_NAG_REL" "AC6: an inert hook never writes the nag file" || rc=1
  hr_teardown; return $rc
}

# --- AC7: orchestrator count() ------------------------------------------------------------------

test_hr_count_two_pages_prints_one_integer() {
  hr_setup; hr_pages_two
  hr_orch_fn count 600 deployer
  local args; args=$(cat "$HR_DIR/gh-args.log" 2>/dev/null)
  local rc=0
  assert_eq "$HR_OUT" "2" "AC7: exactly one integer across two pages" \
    && assert_eq "$HR_RC" "0" "AC7: success status" \
    && assert_contains "$args" "api repos/{owner}/{repo}/issues/600/comments?per_page=100" "AC7: REST endpoint with gh placeholders" \
    && assert_contains "$args" "--paginate" "AC7: paginated read" || rc=1
  hr_teardown; return $rc
}

test_hr_count_zero_markers_prints_zero() {
  hr_setup; hr_pages_offvocab
  hr_orch_fn count 600 deployer
  local rc=0
  assert_eq "$HR_OUT" "0" "AC7: no marker → 0" && assert_eq "$HR_RC" "0" "AC7: zero markers is a successful read" || rc=1
  hr_teardown; return $rc
}

test_hr_count_failed_read_prints_nothing() {
  hr_setup; hr_pages_two; : > "$HR_DIR/gh-fail"
  hr_orch_fn count 600 deployer
  local rc=0
  assert_eq "$HR_OUT" "" "AC7: a failed read must never print 0 (false MARKER FOUND on the next poll)" \
    && assert_ne "$HR_RC" "0" "AC7: a failed read returns non-zero" || rc=1
  hr_teardown; return $rc
}

# --- AC8: orchestrator markers() ---------------------------------------------------------------

test_hr_markers_lists_routing_markers_in_order() {
  hr_setup; hr_pages_markers
  hr_orch_fn markers 600
  local rc=0 want
  want='2026-09-20T23:10:00Z jpmoya **[code-reviewer] PASS**
2026-09-20T23:30:00Z deploy-bot **[deployer] DEPLOYED**'
  assert_eq "$HR_OUT" "$want" "AC8: <created_at> <user.login> <first line>, oldest first, NOTE and off-vocabulary excluded" || rc=1
  hr_teardown; return $rc
}

run_test test_hr_hook_has_no_graphql_read_or_post
run_test test_hr_orchestrator_has_no_graphql_marker_read
run_test test_hr_two_pages_new_marker_lets_stage_stop
run_test test_hr_two_pages_no_new_marker_nags
run_test test_hr_zero_markers_is_not_an_error
run_test test_hr_read_failure_creates_nag_file_with_zero
run_test test_hr_read_failure_advances_mtime_keeps_count
run_test test_hr_nag_message_posts_over_rest
run_test test_hr_two_nag_bound
run_test test_hr_inert_without_before_file_or_env
run_test test_hr_count_two_pages_prints_one_integer
run_test test_hr_count_zero_markers_prints_zero
run_test test_hr_count_failed_read_prints_nothing
run_test test_hr_markers_lists_routing_markers_in_order
