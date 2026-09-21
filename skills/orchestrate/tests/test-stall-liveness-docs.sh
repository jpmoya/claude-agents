# Issue #66 — a live stage at its cap is never killed and never judged by an mtime; the exited path keeps
# recovery and the nag_mtime stall field; deployer bounds its post-merge wait and posts a handoff.
# (Supersedes the #42 assertions, which encoded the nag-file liveness test being removed.)
# Doc assertions against agents/*.md and hooks/; tracked files only.

ROOT_SL=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ORCH_SL="$ROOT_SL/agents/orchestrator.md"
DEPL_SL="$ROOT_SL/agents/deployer.md"

# A branch = its first line through the line before the next blank line / next numbered branch / heading.
sl_branch() {  # $1 = literal that starts the branch line
  awk -v key="$1" '
    index($0, key) && !on { on=1; print; next }
    on && (/^[[:space:]]*$/ || /^[0-9]+\. \*\*/ || /^#/) { exit }
    on { print }' "$ORCH_SL"
}
sl_cap_branch() { sl_branch '2. **Cap hit, process alive**'; }
sl_exited_branch() { sl_branch '1. **Process exited**'; }

test_sl_ac1_no_liveness_mtime_decision() {
  local br; br=$(sl_cap_branch)
  assert_ne "$br" "" "cap-hit-alive branch exists" || return 1
  if grep -qF 'NAG0' "$ORCH_SL"; then fail "AC1: NAG0 baseline still present"; return 1; fi
  if printf '%s\n' "$br" | grep -qiE 'extend \*\*once\*\*|extend once'; then fail "AC1: 'extend once' branch still present"; return 1; fi
  if printf '%s\n' "$br" | grep -qiE 'mtime|nags\.txt|stat '; then fail "AC1: cap-hit branch still reads an mtime/nag file"; return 1; fi
  if grep -qF 'a live process is a working process' "$ORCH_SL"; then fail "AC1: false-premise sentence still present"; return 1; fi
  if grep -qF 'tell them apart' "$ORCH_SL" || grep -qF 'tells them apart' "$ORCH_SL"; then fail "AC1: 'tells them apart' still present"; return 1; fi
  assert_eq 0 0 "AC1 ok"
}

test_sl_ac2_cap_hit_alive_never_kills() {
  local br n; br=$(sl_cap_branch)
  assert_ne "$br" "" "cap-hit-alive branch exists" || return 1
  n=$(grep -c 'kill -9' "$ORCH_SL"); assert_eq "$n" 0 "AC2: 'kill -9' count" || return 1
  if grep -qE 'kill \$PID' "$ORCH_SL"; then fail "AC2: 'kill \$PID' remains"; return 1; fi
  if printf '%s\n' "$br" | grep -qE '(^|[^-])\bkill\b [^ ]*\$'; then fail "AC2: kill in cap-hit branch"; return 1; fi
  printf '%s\n' "$br" | grep -qiE 'stop polling' || { fail "AC2: must say stop polling"; return 1; }
  printf '%s\n' "$br" | grep -qF 'tail -3' || { fail "AC2: tail -3 kept"; return 1; }
  printf '%s\n' "$br" | grep -qiE 'report' || { fail "AC2: must say reporting only / report to JP"; return 1; }
  printf '%s\n' "$br" | grep -qF '"outcome":"no-marker"' || { fail "AC2: must log outcome no-marker"; return 1; }
  printf '%s\n' "$br" | grep -qiE 'still running' || { fail "AC2: must report stage as still running"; return 1; }
  printf '%s\n' "$br" | grep -qiE 'unreported' || { fail "AC2: must report stage as unreported"; return 1; }
  assert_eq 0 0 "AC2 ok"
}

test_sl_ac3_recovery_only_when_exited() {
  local cap ex; cap=$(sl_cap_branch); ex=$(sl_exited_branch)
  assert_ne "$cap" "" "cap-hit-alive branch exists" || return 1
  printf '%s\n' "$ex" | grep -qiE 'handoff recovery' || { fail "AC3: exited branch must dispatch handoff recovery"; return 1; }
  if printf '%s\n' "$cap" | grep -qiE 'recovery|re-dispatch|redispatch|recover'; then fail "AC3: cap-hit-alive branch instructs recovery/re-dispatch"; return 1; fi
  assert_eq 0 0 "AC3 ok"
}

test_sl_ac4_nag_mtime_only_on_exited_stall_line() {
  local cap ex n; cap=$(sl_cap_branch); ex=$(sl_exited_branch)
  assert_ne "$cap" "" "cap-hit-alive branch exists" || return 1
  printf '%s\n' "$ex" | grep -qF '"outcome":"stall"' || { fail "AC4: exited branch keeps outcome stall"; return 1; }
  printf '%s\n' "$ex" | grep -qF 'nag_mtime' || { fail "AC4: exited stall line keeps nag_mtime"; return 1; }
  if printf '%s\n' "$cap" | grep -qF 'nag_mtime'; then fail "AC4: nag_mtime must not appear in cap-hit-alive branch"; return 1; fi
  if printf '%s\n' "$cap" | grep -qF '"outcome":"stall"'; then fail "AC4: cap-hit-alive must not log stall"; return 1; fi
  # vocabulary unchanged
  grep -qF 'one of `marker` / `recovered` / `no-marker` / `stall` / `error`' "$ORCH_SL" || { fail "AC4: outcome vocabulary changed"; return 1; }
  assert_eq 0 0 "AC4 ok"
}

test_sl_ac5_stage_caps_unchanged() {
  local want='**Stage caps** (process alive, no marker): reviewers, deployer, infra-reviewer **10 min**; product-manager, ux-flow-designer, infra-planner **15 min**; test-writer, fullstack-developer (and fix cycles), ui-ux-designer, infra-operator **30 min**.'
  local got; got=$(grep -F '**Stage caps**' "$ORCH_SL")
  assert_eq "$got" "$want" "AC5: stage caps line byte-for-byte"
}

sl_deployer_postmerge() {
  awk '/^- \*\*Post-merge:\*\*/ { on=1; print; next } on && /^- \*\*/ { exit } on { print }' "$DEPL_SL"
}

test_sl_ac6_deployer_in_progress_outcome() {
  local pm; pm=$(sl_deployer_postmerge)
  assert_ne "$pm" "" "deployer post-merge bullet exists" || return 1
  printf '%s\n' "$pm" | grep -qF '3 minutes' || { fail "AC6: 3-minute bound kept"; return 1; }
  printf '%s\n' "$pm" | grep -qF 'in_progress' || { fail "AC6: must name in_progress"; return 1; }
  printf '%s\n' "$pm" | grep -qF 'run URL' || { fail "AC6: must say it posts the run URL"; return 1; }
  printf '%s\n' "$pm" | grep -qF 'stop waiting' || { fail "AC6: must say 'stop waiting'"; return 1; }
  assert_eq 0 0 "AC6 ok"
}

test_sl_ac7_no_new_mechanism() {
  local n h; n=$(ls "$ROOT_SL/hooks" | wc -l | tr -d ' ')
  assert_eq "$n" 11 "AC7: hooks/ file count unchanged" || return 1
  h=$(git hash-object "$ROOT_SL/hooks/require-handoff-marker.sh")
  assert_eq "$h" 73de42d9cb5613f423bd62337b40e8b67b9cac00 "AC7: require-handoff-marker.sh unmodified" || return 1
  if sl_cap_branch | grep -qiE 'heartbeat|reaper|timer|counter'; then fail "AC7: new mechanism in cap-hit branch"; return 1; fi
  assert_eq 0 0 "AC7 ok"
}

run_test test_sl_ac1_no_liveness_mtime_decision
run_test test_sl_ac2_cap_hit_alive_never_kills
run_test test_sl_ac3_recovery_only_when_exited
run_test test_sl_ac4_nag_mtime_only_on_exited_stall_line
run_test test_sl_ac5_stage_caps_unchanged
run_test test_sl_ac6_deployer_in_progress_outcome
run_test test_sl_ac7_no_new_mechanism
