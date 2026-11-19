# #793 (JP, 2026-11-19): a goal that cannot be read blocks NOTHING but itself.
#   - a project goal whose scope read fails leaves a marker ($PIPE/goal-proj-err-<owner>_<n>); the queue jq skips it (no slot, no candidate) for
#     GOAL_SCOPE_ERR_SECS and every other goal goes on in the same priority order; a registry entry whose block cannot be read is skipped too
#   - a failed `gh` call is retried twice before anything is logged; a parse / closed / missing answer is final (no retry)
#   - goal_queue_step skips a candidate whose scope cannot be read (no claim, no launch) and recomputes the queue without it
#   - a readable ACTIVE goal still holds the one slot (the slot logic is otherwise unchanged)
# Expected values are hand-written. Prefix ug_.

UG_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ug_env() { UG_PIPE=$(new_pipe); UG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ug-test.XXXXXX"); mkdir -p "$UG_DIR/bin"; : > "$UG_DIR/calls.log"; }
ug_cleanup() { rm -rf "$UG_PIPE" "$UG_DIR"; return 0; }

# ug_goal <registry issue> <id> <st> <priority> [<owner>/<number> scope project]
ug_goal() {
  jq -nc --argjson n "$1" --arg id "$2" --arg st "$3" --arg p "$4" --arg sp "${5:-}" '
    {issue:$n, id:$id, spec:"project:\($sp)", host:"", instructions:"", state:"open", closed_at:null, st:$st,
     block:({v:1, id:$id, priority:($p|tonumber)} + (if $sp == "" then {} else {scope_project:{owner:($sp|split("/")[0]), number:($sp|split("/")[1]|tonumber), url:"u"}} end))}'
}

# ug_lib <script> — goal-lib.sh sourced in a subshell on the private PIPE; fake gh first on PATH
ug_lib() {
  bash -c ". '$UG_SKILL/config.sh' >/dev/null 2>&1; PIPE='$UG_PIPE'; . '$UG_SKILL/pipeline-lib.sh' >/dev/null 2>&1; . '$UG_SKILL/goal-lib.sh' >/dev/null 2>&1; PIPE='$UG_PIPE'
    slog() { :; }; GOAL_PROJ_RETRY_SECS=0; $1" 2>"$UG_DIR/err"
}
# ug_q <serial 0|1> <field> <goal json>... -> the field of the queue computed with the markers in $UG_PIPE (id of an object, "null" for none)
ug_q() {
  local s=$1 field=$2 reg; shift 2
  reg=$(printf '%s\n' "$@" | jq -sc '.')
  UG_REG="$reg" ug_lib "GOAL_SERIAL=$s; printf '%s' \"\$UG_REG\" | _goal_queue_jq \" | (.$field | if type == \\\"object\\\" then .id elif . == null then \\\"null\\\" else . end)\" | jq -c ."
}

ug_marker() {  # ug_marker <owner/number> <seconds ago> <reason>
  printf '%s\t%s\n' "$(( $(date +%s) - $2 ))" "$3" > "$UG_PIPE/goal-proj-err-$(printf '%s' "${1%%/*}" | tr '[:upper:]' '[:lower:]')_${1##*/}"
}

test_ug_an_errored_goal_at_the_head_does_not_block_the_next_queued_goal() {
  ug_env; ug_marker jpmoya/41 30 "an items page does not parse"
  local a b rc=0
  a=$(ug_q 1 candidate "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)")
  b=$(ug_q 1 queued "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)" | jq -c 'map(.id)' 2>/dev/null)
  assert_eq "$a" '"sales-wf"' "serial: the unreadable goal at priority 1 is skipped, the next queued goal is the candidate" || rc=1
  assert_eq "$(ug_q 1 errored "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)")" \
    '[{"id":"cd-hardening","issue":50,"why":"an items page does not parse"}]' "the skipped goal is listed with the reason (display)" || rc=1
  assert_eq "$(ug_q 0 candidate "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)")" '"sales-wf"' \
    "GOAL_SERIAL=0: skipped too" || rc=1
  ug_cleanup; return $rc
}

test_ug_an_errored_active_goal_does_not_hold_the_slot() {
  ug_env; ug_marker jpmoya/41 30 "gh exit 1: HTTP 502"
  local rc=0
  assert_eq "$(ug_q 1 slot "$(ug_goal 50 cd-hardening active 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)")" '"null"' "the slot is free" || rc=1
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 cd-hardening active 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)")" '"sales-wf"' \
    "the queued goal takes the slot while the unreadable goal is active but skipped" || rc=1
  ug_cleanup; return $rc
}

test_ug_the_order_of_the_other_goals_is_unchanged_and_a_readable_active_goal_still_holds_the_slot() {
  ug_env; ug_marker jpmoya/41 30 "x"
  local rc=0
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1 jpmoya/41)" "$(ug_goal 51 c queued 3 jpmoya/43)" "$(ug_goal 52 b queued 2 jpmoya/42)" "$(ug_goal 53 d queued 4 jpmoya/44)")" '"b"' \
    "A skipped; B (priority 2) before C (3) before D (4)" || rc=1
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1 jpmoya/41)" "$(ug_goal 51 x active 5 jpmoya/45)" "$(ug_goal 52 b queued 2 jpmoya/42)")" '"null"' \
    "a readable active goal still holds the one slot" || rc=1
  assert_eq "$(ug_q 1 slot "$(ug_goal 50 a active 1 jpmoya/41)" "$(ug_goal 51 x active 5 jpmoya/45)")" '"x"' "the slot is the first READABLE active goal" || rc=1
  ug_cleanup; return $rc
}

test_ug_only_the_goal_of_the_failed_project_is_skipped() {
  ug_env; ug_marker JPMoya/41 30 "x"
  local rc=0
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1 jpmoya/42)" "$(ug_goal 51 b queued 2 jpmoya/41)")" '"a"' "project 42 is not project 41" || rc=1
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1 other/41)" "$(ug_goal 51 b queued 2 jpmoya/41)")" '"a"' "another owner's project 41 is not skipped" || rc=1
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1)" "$(ug_goal 51 b queued 2 jpmoya/41)")" '"a"' "a goal with no scope project is never skipped" || rc=1
  assert_eq "$(ug_q 1 errored "$(ug_goal 50 a queued 1 JPMOYA/41)")" '[{"id":"a","issue":50,"why":"x"}]' "owner case does not matter" || rc=1
  ug_cleanup; return $rc
}

test_ug_a_stale_marker_is_ignored() {
  ug_env; ug_marker jpmoya/41 4000 "old"   # older than GOAL_SCOPE_ERR_SECS (1800)
  assert_eq "$(ug_q 1 candidate "$(ug_goal 50 a queued 1 jpmoya/41)" "$(ug_goal 51 b queued 2 jpmoya/42)")" '"a"' "an old failure no longer skips the goal (it is probed again)" || { ug_cleanup; return 1; }
  ug_cleanup
}

test_ug_an_unreadable_registry_entry_is_skipped_and_listed() {
  ug_env
  local rc=0 bad
  bad='{"issue":9,"id":"registry-issue-9","spec":"","host":"","state":"open","closed_at":null,"block":null,"st":"unreadable"}'
  assert_eq "$(ug_q 1 candidate "$bad" "$(ug_goal 51 b queued 2 jpmoya/42)")" '"b"' "serial: a registry entry with no readable block blocks nothing" || rc=1
  assert_eq "$(ug_q 1 unreadable "$bad" "$(ug_goal 51 b queued 2 jpmoya/42)")" '[{"id":"registry-issue-9","issue":9}]' "and is still listed" || rc=1
  ug_cleanup; return $rc
}

# ---------------------------------------------------------------- the read: retries and markers ----------------------

# ug_gh <fail-first N> <page mode: ok|noodes> — a fake gh serving one items page; the first N calls exit 1
ug_gh() {
  echo "$1" > "$UG_DIR/failfirst"; echo "$2" > "$UG_DIR/mode"
  cat > "$UG_DIR/bin/gh" <<'UG_GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
echo "$*" >> "$D/calls.log"
n=$(wc -l < "$D/calls.log" | tr -d ' ')
if [ "$n" -le "$(cat "$D/failfirst")" ]; then echo "HTTP 502 bad gateway" >&2; exit 1; fi
if [ "$(cat "$D/mode")" = noodes ]; then
  echo '{"data":{"repositoryOwner":{"projectV2":{"title":"Goal: x","url":"u","closed":false,"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":null}}}}}'
else
  echo '{"data":{"repositoryOwner":{"projectV2":{"title":"Goal: x","url":"u","closed":false,"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
fi
UG_GH_EOF
  chmod +x "$UG_DIR/bin/gh"
}
ug_read() { PATH="$UG_DIR/bin:$PATH" ug_lib "_goal_proj_read jpmoya/41 >/dev/null; echo rc=\$?"; }

test_ug_a_failed_gh_call_is_retried_twice_before_the_goal_is_marked() {
  ug_env; ug_gh 99 ok
  local out; out=$(ug_read)
  assert_eq "$out" "rc=1" "gh keeps failing: the read fails" || { ug_cleanup; return 1; }
  assert_eq "$(wc -l < "$UG_DIR/calls.log" | tr -d ' ')" "3" "1 try + 2 retries" || { ug_cleanup; return 1; }
  assert_contains "$(cat "$UG_PIPE/goal-proj-err-jpmoya_41" 2>/dev/null)" "gh exit 1" "the goal is marked with gh's reason" || { ug_cleanup; return 1; }
  ug_cleanup
}

test_ug_a_transient_gh_failure_that_clears_logs_nothing_and_leaves_no_marker() {
  ug_env; ug_gh 2 ok
  local out; out=$(ug_read)
  assert_eq "$out" "rc=0" "two failures then a good page: the read succeeds" || { ug_cleanup; return 1; }
  assert_eq "$(wc -l < "$UG_DIR/calls.log" | tr -d ' ')" "3" "two retries were used" || { ug_cleanup; return 1; }
  [ ! -e "$UG_PIPE/goal-proj-err-jpmoya_41" ] || { ug_cleanup; fail "no marker after a good read"; return 1; }
  assert_eq "$(cat "$UG_DIR/err")" "" "nothing logged for the transient failures" || { ug_cleanup; return 1; }
  ug_cleanup
}

test_ug_a_good_read_clears_an_old_marker() {
  ug_env; ug_gh 0 ok; ug_marker jpmoya/41 60 "old"
  local out; out=$(ug_read)
  assert_eq "$out" "rc=0" "reads fine" || { ug_cleanup; return 1; }
  [ ! -e "$UG_PIPE/goal-proj-err-jpmoya_41" ] || { ug_cleanup; fail "the marker is cleared"; return 1; }
  ug_cleanup
}

test_ug_a_one_item_meta_read_never_clears_the_marker() {
  ug_env; ug_gh 0 ok; ug_marker jpmoya/41 60 "an items page does not parse"
  local out; out=$(PATH="$UG_DIR/bin:$PATH" ug_lib "_goal_proj_read jpmoya/41 --meta >/dev/null; echo rc=\$?")
  assert_eq "$out" "rc=0" "the --meta read itself succeeds" || { ug_cleanup; return 1; }
  [ -e "$UG_PIPE/goal-proj-err-jpmoya_41" ] || { ug_cleanup; fail "a --meta read (goal name, start probe) must not wipe a failure only a full read sees"; return 1; }
  ug_cleanup
}

test_ug_a_page_that_does_not_parse_is_final_no_retry() {
  ug_env; ug_gh 0 noodes
  local out; out=$(ug_read)
  assert_eq "$out" "rc=1" "the read fails" || { ug_cleanup; return 1; }
  assert_eq "$(wc -l < "$UG_DIR/calls.log" | tr -d ' ')" "1" "one call: a parse failure is not retried" || { ug_cleanup; return 1; }
  assert_eq "$(cut -f2 "$UG_PIPE/goal-proj-err-jpmoya_41")" "an items page does not parse" "marked with the reason" || { ug_cleanup; return 1; }
  ug_cleanup
}

# ---------------------------------------------------------------- the queue file and the start step ------------------

test_ug_queue_save_lists_the_errored_goal_and_names_the_next_candidate() {
  ug_env; ug_marker jpmoya/41 30 "the project is closed"
  local reg out
  reg=$(printf '%s\n' "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" "$(ug_goal 51 sales-wf queued 2 jpmoya/42)" | jq -sc '.')
  out=$(UG_REG="$reg" ug_lib "GOAL_SERIAL=1; goal_queue_save \"\$UG_REG\"; jq -c '{candidate, errored, queued: (.queued | map(.id))}' '$UG_PIPE/goalqueue.json'")
  ug_cleanup
  assert_eq "$out" '{"candidate":"sales-wf","errored":[{"id":"cd-hardening","issue":50,"why":"the project is closed"}],"queued":["cd-hardening","sales-wf"]}' \
    "goalqueue.json: the next goal is the candidate, the skipped one is listed with its reason, both stay queued in order" || return 1
}

# goal_queue_step with a candidate whose project cannot be read: nothing is claimed or launched, the marker is set, the queue is saved again
test_ug_the_start_step_skips_a_candidate_whose_scope_cannot_be_read() {
  ug_env; ug_gh 99 ok
  local reg out
  reg=$(printf '%s\n' "$(ug_goal 50 cd-hardening queued 1 jpmoya/41)" | jq -sc 'map(.block.hosts = "mac")')
  printf '%s' "$reg" > "$UG_DIR/reg.json"
  jq -c '{candidate: "cd-hardening", queued: [{id: "cd-hardening", issue: 50, host_pref: "", hosts: "any"}]}' <<< '{}' > "$UG_PIPE/goalqueue.json"
  out=$(PATH="$UG_DIR/bin:$PATH" ug_lib "
    GOAL_SERIAL=1; GOAL_CAN_LAUNCH=1; GOAL_THIS_HOST=h1; CLAIM_WINDOW_SECS=0; goal_is_mac() { return 1; }
    _goal_queue_unhold() { :; }; _goal_registry_json() { cat '$UG_DIR/reg.json'; }
    _goal_note() { echo NOTE >> '$UG_DIR/acts'; }; _goal_checkout() { echo CHECKOUT >> '$UG_DIR/acts'; return 0; }; goal_launch() { echo LAUNCH >> '$UG_DIR/acts'; }
    goal_queue_save() { echo SAVED >> '$UG_DIR/acts'; }
    goal_queue_step; echo rc=\$?")
  assert_eq "$out" "rc=0" "the step returns normally" || { ug_cleanup; return 1; }
  assert_eq "$(cat "$UG_DIR/acts" 2>/dev/null | tr '\n' ' ')" "SAVED " "no checkout, claim note or launch; the queue is saved again without it" || { ug_cleanup; return 1; }
  [ -f "$UG_PIPE/goal-proj-err-jpmoya_41" ] || { ug_cleanup; fail "the goal is marked"; return 1; }
  ug_cleanup
}

echo "-- unreadable goal blocks only itself (#793)"
for t in test_ug_an_errored_goal_at_the_head_does_not_block_the_next_queued_goal test_ug_an_errored_active_goal_does_not_hold_the_slot \
         test_ug_the_order_of_the_other_goals_is_unchanged_and_a_readable_active_goal_still_holds_the_slot test_ug_only_the_goal_of_the_failed_project_is_skipped \
         test_ug_a_stale_marker_is_ignored test_ug_an_unreadable_registry_entry_is_skipped_and_listed \
         test_ug_a_failed_gh_call_is_retried_twice_before_the_goal_is_marked test_ug_a_transient_gh_failure_that_clears_logs_nothing_and_leaves_no_marker \
         test_ug_a_good_read_clears_an_old_marker test_ug_a_one_item_meta_read_never_clears_the_marker test_ug_a_page_that_does_not_parse_is_final_no_retry \
         test_ug_queue_save_lists_the_errored_goal_and_names_the_next_candidate test_ug_the_start_step_skips_a_candidate_whose_scope_cannot_be_read; do
  run_test "$t"
done
