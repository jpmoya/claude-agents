# Issue #114 — AC6 + AC9: label decisions of the intake agent live in skills/orchestrate/intake-labels.sh.
# Contract chosen from the ticket (it names the file, not the CLI): `intake-labels.sh <bug|idea|unclear>` prints one
# operation per line, `add <label>` or `remove <label>`, exit 0; any other/missing type → non-zero exit, no stdout.
# INTAKE_AUTO_GO comes from config.sh (default 0; HOME's config.local.sh may override, sourced after).
# Expected sets are hand-written from the ticket's Expected Behavior §6 and AC9.

HERE_IL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IL="$HERE_IL/../intake-labels.sh"

# il_ops <type> <auto_go|none> → sorted, space-joined ops; sets IL_RC
il_ops() {
  local home out; home=$(new_home)
  [ "$2" = none ] || echo "INTAKE_AUTO_GO=$2" > "$home/.claude/pipeline/config.local.sh"
  out=$(HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$IL" ${1:+"$1"} 2>/dev/null); IL_RC=$?
  rm -rf "$home"
  IL_OUT=$(printf '%s\n' "$out" | sort | tr '\n' ',')
}

test_il_config_default_is_one_and_documented() {
  local line
  line=$(grep -E '^INTAKE_AUTO_GO=' "$HERE_IL/../config.sh")
  # #115 AC6/D: default flipped from 0 to 1
  assert_eq "${line%%[[:space:]#]*}" "INTAKE_AUTO_GO=1" "#115 AC6: config.sh sets INTAKE_AUTO_GO=1 by default" || return 1
}

test_il_bug_auto_go_off_adds_proposed_not_go() {
  local got; il_ops bug 0; got=$IL_OUT
  assert_exit0 "$IL_RC" "bug/0 exits 0" || return 1
  assert_eq "$got" "add agent-proposed,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "AC9: bug with INTAKE_AUTO_GO=0" || return 1
}

test_il_bug_default_config_behaves_as_auto_go_on() {
  local got; il_ops bug none; got=$IL_OUT
  # #115 AC6/D: default is now 1 => bug goes straight to agent-go
  assert_eq "$got" "add agent-go,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "#115 AC6: bug with no override = default 1" || return 1
}

test_il_bug_auto_go_on_adds_go_not_proposed() {
  local got; il_ops bug 1; got=$IL_OUT
  assert_exit0 "$IL_RC" "bug/1 exits 0" || return 1
  assert_eq "$got" "add agent-go,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "AC6/AC9: bug with INTAKE_AUTO_GO=1" || return 1
}

test_il_idea_never_gets_agent_go() {
  local v got
  for v in 0 1; do
    il_ops idea "$v"; got=$IL_OUT
    assert_exit0 "$IL_RC" "idea/$v exits 0" || return 1
    assert_eq "$got" "add user-feedback,add user-feedback-needs-spec,remove user-feedback-intake," "AC6: idea with INTAKE_AUTO_GO=$v" || return 1
  done
}

test_il_unclear_is_treated_as_idea() {
  local v got
  for v in 0 1; do
    il_ops unclear "$v"; got=$IL_OUT
    assert_eq "$got" "add user-feedback,add user-feedback-needs-spec,remove user-feedback-intake," "AC6: unclear with INTAKE_AUTO_GO=$v" || return 1
  done
}

test_il_only_removal_is_the_intake_label() {
  local t v got
  for t in bug idea unclear; do for v in 0 1; do
    il_ops $t $v; got=$IL_OUT
    assert_eq "$(printf '%s' "$got" | tr ',' '\n' | grep -c '^remove ')" "1" "$t/$v: exactly one removal" || return 1
    assert_contains "$got" "remove user-feedback-intake," "$t/$v: the removal is user-feedback-intake" || return 1
  done; done
}

test_il_unknown_or_missing_type_is_rejected() {
  local got
  il_ops bug 1 >/dev/null; assert_exit0 "$IL_RC" "control: a valid type succeeds" || return 1
  il_ops banana 1; got=$IL_OUT
  assert_ne "$IL_RC" "0" "unknown type: non-zero exit" || return 1
  assert_eq "$got" "," "unknown type: prints no operations" || return 1
  il_ops "" 1; got=$IL_OUT
  assert_ne "$IL_RC" "0" "missing type: non-zero exit" || return 1
  assert_eq "$got" "," "missing type: prints no operations" || return 1
}

run_test test_il_config_default_is_one_and_documented
run_test test_il_bug_auto_go_off_adds_proposed_not_go
run_test test_il_bug_default_config_behaves_as_auto_go_on
run_test test_il_bug_auto_go_on_adds_go_not_proposed
run_test test_il_idea_never_gets_agent_go
run_test test_il_unclear_is_treated_as_idea
run_test test_il_only_removal_is_the_intake_label
run_test test_il_unknown_or_missing_type_is_rejected
