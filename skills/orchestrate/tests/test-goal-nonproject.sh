# JP rule (2026-11-18): every goal is registered as a GitHub Project (`project:<owner>/<n>`), never as a milestone, label or ticket
# goal (the standing owner/repo:feedback goals keep their spec: slot exemption and scope are keyed on it), and ONE name is used everywhere ("Goal: <Name>" for the project and the registry issue, <Name> on the status page).
# Issue #736 / PR #745 added the project form but nothing stopped milestone goals from still being registered (#544 milestone 136,
# #618 Client portal V1 were registered after it). Two mechanisms, one text:
#   gnm_hook_*    hooks/block-nonproject-goal.sh (PreToolUse on Bash): blocks a deliver.sh REGISTER call whose goal spec is not a project
#                 (milestone, milestones:all, label, bare --repos label registration, #N; the standing owner/repo:feedback goal keeps its spec and passes) and a `gh project create|edit --title
#                 "Goal: ..."` that breaks the naming convention; stop/release/status/resume/priority/project and the project forms pass.
#   gnm_deliver_* deliver.sh itself refuses every non-project registration unless GOAL_ALLOW_LEGACY_REGISTER=1 (legacy tooling); existing
#                 goals keep working (status, stop, release, resume, priority).
#   gnm_name_*    the naming helpers in goal-lib.sh (goal_title, goal_name_of_title, goal_title_check)
#   gnm_docs_*    the how-to is written down (SKILL.md, README) and the hook is wired in settings.json.
# Reading of #736: it makes a Project the scope source and says existing milestone goals keep working ("not auto-converted"). JP's later rule
# (2026-11-18) goes further: new registrations of any other kind are refused too. Registered goals of the old kinds (also the four JP re-spec'd
# to projects by hand) are untouched.
# Loaded after test-goal-deliver.sh (alphabetical): reuses the dg_* sandbox. run-tests.sh exports GOAL_ALLOW_LEGACY_REGISTER=1 for the
# other suites, so every case here unsets it around the call. Prefix gnm_ / GNM_. Expected values are hand-written, never from the code.

GNM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
GNM_HOOK="$GNM_ROOT/hooks/block-nonproject-goal.sh"
GNM_HINT='project:<owner>/<n>'

# gnm_hook <command> [json-tool-name] — runs the hook on a Bash tool call; sets GNM_RC / GNM_ERR
gnm_hook() {
  local cmd=$1 tool=${2:-Bash} in
  in=$(jq -nc --arg c "$cmd" --arg t "$tool" '{tool_name:$t, tool_input:{command:$c}}')
  GNM_ERR=$(printf '%s' "$in" | env -u GOAL_ALLOW_LEGACY_REGISTER bash "$GNM_HOOK" 2>&1 >/dev/null); GNM_RC=$?
}

gnm_blocked() {  # <label> <command>
  gnm_hook "$2"
  assert_eq "$GNM_RC" "2" "$1: blocked" || return 1
  assert_contains "$GNM_ERR" "$GNM_HINT" "$1: names the project form" || return 1
  assert_contains "$GNM_ERR" "gh project create" "$1: says how to create the project" || return 1
}
gnm_allowed() {  # <label> <command>
  gnm_hook "$2"
  assert_eq "$GNM_RC" "0" "$1: allowed (stderr: $GNM_ERR)" || return 1
}

test_gnm_hook_exists_and_is_executable_bash() {
  [ -x "$GNM_HOOK" ] || { fail "hooks/block-nonproject-goal.sh is missing or not executable"; return 1; }
  assert_eq "$(head -1 "$GNM_HOOK")" "#!/bin/bash" "shebang like the other hooks"
}

test_gnm_hook_blocks_milestone_registration_in_every_shape() {
  local rc=0
  gnm_blocked "plain milestone" 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:milestone:136' || rc=1
  gnm_blocked "installed path, flags after" '~/.claude/skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:milestone:136 --now --priority 2' || rc=1
  gnm_blocked "milestone by title" 'deliver.sh "Benjis-Plants/benjis-ops-tool:milestone:Client portal V1" "go carefully"' || rc=1
  gnm_blocked "milestones:all" './deliver.sh Benjis-Plants/benjis-sales-tool:milestones:all --approve-all' || rc=1
  gnm_blocked "literal register word" 'deliver.sh register Benjis-Plants/benjis-ops-tool:milestone:136' || rc=1
  gnm_blocked "after cd and &&" 'cd ~/dev/claude-agents && skills/orchestrate/deliver.sh a/b:milestone:5' || rc=1
  gnm_blocked "after a pipe-less semicolon" 'echo go; skills/orchestrate/deliver.sh a/b:milestone:5; echo done' || rc=1
  gnm_blocked "on a new line" $'set -e\nskills/orchestrate/deliver.sh a/b:milestone:5\n' || rc=1
  gnm_blocked "env prefix is no way round it" 'GOAL_ALLOW_LEGACY_REGISTER=1 skills/orchestrate/deliver.sh a/b:milestone:5' || rc=1
  gnm_blocked "bash wrapper" 'bash ~/.claude/skills/orchestrate/deliver.sh a/b:milestone:5' || rc=1
  gnm_blocked "nohup wrapper" 'nohup skills/orchestrate/deliver.sh a/b:milestone:5 >/dev/null 2>&1 &' || rc=1
  gnm_blocked "bash -c string" "bash -c 'skills/orchestrate/deliver.sh a/b:milestone:5'" || rc=1
  gnm_blocked "on the VM over ssh" "ssh clog-exec 'cd ~/claude-agents && skills/orchestrate/deliver.sh a/b:milestone:5'" || rc=1
  gnm_blocked "command substitution" 'echo $(skills/orchestrate/deliver.sh a/b:milestone:5)' || rc=1
  gnm_blocked "label goal" 'skills/orchestrate/deliver.sh label:Q4 --repos a/b,c/d --title T' || rc=1
  gnm_blocked "label goal by --repos only" 'skills/orchestrate/deliver.sh --repos a/b,c/d --title "Q4" --now' || rc=1
  gnm_blocked "ticket goal" 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool#2169' || rc=1
  gnm_blocked "project spec with no number" 'skills/orchestrate/deliver.sh project:Benjis-Plants' || rc=1
  gnm_blocked "register word then a label goal" 'skills/orchestrate/deliver.sh register label:Q4 --repos a/b' || rc=1
  return $rc
}

# JP, 2026-11-18: no default go. A project registration that states neither --go nor --no-go is the session guessing: blocked, with the question.
test_gnm_hook_blocks_a_project_registration_that_omits_the_go_choice() {
  local rc=0 c
  for c in 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --priority 2' \
           'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --now --priority 2' \
           'skills/orchestrate/deliver.sh register project:Benjis-Plants/12 --priority 2' \
           'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:project:12 --host claude --priority 2' \
           "ssh clog-exec 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --now --priority 2'" \
           'GOAL_ALLOW_LEGACY_REGISTER=1 skills/orchestrate/deliver.sh project:Benjis-Plants/12 --priority 2'; do
    gnm_blocked "no go choice: $c" "$c" || rc=1
    assert_contains "$GNM_ERR" "ask JP: go true or go false?" "asks the question: $c" || rc=1
    assert_contains "$GNM_ERR" "--no-go" "names both flags: $c" || rc=1
  done
  gnm_allowed "go stated" 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --go --priority 1' || rc=1
  gnm_allowed "no-go stated" 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --no-go --priority 1 --now' || rc=1
  gnm_allowed "stop needs no go" 'skills/orchestrate/deliver.sh stop proj-Benjis-Plants_12' || rc=1
  return $rc
}

# JP, 2026-11-18 (final): the priority is OPTIONAL. A project registration with --go / --no-go and no --priority is fine; the hook never asks for it.
test_gnm_hook_does_not_require_a_priority() {
  local rc=0 c
  for c in 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --go' \
           'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --no-go --now' \
           "ssh clog-exec 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:project:12 --go'"; do
    gnm_allowed "no priority is fine: $c" "$c" || rc=1
  done
  gnm_hook 'skills/orchestrate/deliver.sh project:Benjis-Plants/12'
  assert_eq "$GNM_RC" "2" "no go choice: blocked" || rc=1
  assert_not_contains "$GNM_ERR" "ask JP for the priority" "the hook never asks for a priority" || rc=1
  assert_contains "$GNM_ERR" "Priority only orders the queue" "the queue-order note is in the message" || rc=1
  assert_contains "$GNM_ERR" "Priority 1 does NOT make a goal start immediately" "the no-preempt note" || rc=1
  assert_contains "$GNM_ERR" "stop the goal that holds the slot" "how to force it: stop the holder" || rc=1
  assert_contains "$GNM_ERR" "--now" "how to force it: --now" || rc=1
  return $rc
}

test_gnm_hook_names_the_whole_recipe() {
  gnm_hook 'skills/orchestrate/deliver.sh a/b:milestone:5'
  local rc=0
  assert_contains "$GNM_ERR" "gh project item-add" "tells to add the tickets" || rc=1
  assert_contains "$GNM_ERR" "deliver.sh project:Benjis-Plants/" "shows the register command" || rc=1
  assert_contains "$GNM_ERR" "a/b:milestone:5" "says what was refused" || rc=1
  assert_contains "$GNM_ERR" "Goal: <short human name>" "gives the naming convention" || rc=1
  return $rc
}

test_gnm_hook_lets_other_subcommands_and_goal_forms_through() {
  local rc=0
  gnm_allowed "stop a milestone goal" 'skills/orchestrate/deliver.sh stop a/b:milestone:5' || rc=1
  gnm_allowed "release" 'skills/orchestrate/deliver.sh release a/b:milestone:5' || rc=1
  gnm_allowed "resume with --here" 'skills/orchestrate/deliver.sh resume a/b:milestone:5 --here' || rc=1
  gnm_allowed "status of a milestone goal" 'skills/orchestrate/deliver.sh status a/b:milestone:5' || rc=1
  gnm_allowed "status, no args" 'skills/orchestrate/deliver.sh status' || rc=1
  gnm_allowed "priority" 'skills/orchestrate/deliver.sh priority a/b:milestone:5 1' || rc=1
  gnm_allowed "priority --after" 'skills/orchestrate/deliver.sh priority a/b:milestone:5 --after a/b:milestone:6' || rc=1
  gnm_allowed "project bind" 'skills/orchestrate/deliver.sh project a/b:milestone:5 --create' || rc=1
  gnm_allowed "stop by id over ssh" "ssh clog-exec 'skills/orchestrate/deliver.sh stop a_b-ms-5'" || rc=1
  gnm_allowed "project goal, go" 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --go --priority 3 --now' || rc=1
  gnm_allowed "project goal, no-go" 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --no-go --priority 3' || rc=1
  gnm_allowed "project goal, register word" 'skills/orchestrate/deliver.sh register project:Benjis-Plants/12 --go --priority 1' || rc=1
  gnm_allowed "project goal, repo alias" 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:project:12 --no-go --priority 2' || rc=1
  gnm_allowed "project goal with instructions that mention a milestone" 'skills/orchestrate/deliver.sh project:Benjis-Plants/12 --go --priority 2 "ignore a/b:milestone:5 and label:x"' || rc=1
  gnm_allowed "project goal, flags in any order" 'skills/orchestrate/deliver.sh project:jpmoya/46 --now --priority 2 --host claude --go' || rc=1
  gnm_allowed "project goal, --priority=N form" 'skills/orchestrate/deliver.sh project:jpmoya/46 --go --priority=4' || rc=1
  gnm_allowed "project goal with no priority at all" 'skills/orchestrate/deliver.sh project:jpmoya/46 --no-go' || rc=1
  gnm_allowed "standing feedback goal keeps its spec (no go choice, no priority)" 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:feedback' || rc=1
  gnm_allowed "standing feedback goal, register word, --now" 'skills/orchestrate/deliver.sh register Benjis-Plants/benjis-sales-tool:feedback --now' || rc=1
  gnm_blocked "a spec that only looks like feedback" 'skills/orchestrate/deliver.sh Benjis-Plants/benjis-ops-tool:feedback:extra' || rc=1
  gnm_allowed "help" 'skills/orchestrate/deliver.sh --help' || rc=1
  return $rc
}

test_gnm_hook_ignores_text_that_only_mentions_deliver_sh() {
  local rc=0
  gnm_allowed "echo" 'echo "run deliver.sh a/b:milestone:5 to register"' || rc=1
  gnm_allowed "grep" 'grep -rn "deliver.sh a/b:milestone:5" skills/' || rc=1
  gnm_allowed "gh comment body" 'gh issue comment 5 --repo a/b --body "registered with deliver.sh a/b:milestone:5"' || rc=1
  gnm_allowed "git commit message" 'git commit -m "docs: deliver.sh a/b:milestone:5 is refused now"' || rc=1
  gnm_allowed "cat of a file named like the script" 'cat skills/orchestrate/deliver.sh' || rc=1
  gnm_allowed "no deliver.sh at all" 'gh api repos/a/b/milestones/5' || rc=1
  return $rc
}

test_gnm_hook_never_wedges_on_odd_input() {
  local rc=0 out
  gnm_hook 'skills/orchestrate/deliver.sh a/b:milestone:5' Read; assert_eq "$GNM_RC" "2" "the tool name is not trusted: the command decides" || rc=1
  out=$(printf 'not json' | bash "$GNM_HOOK" 2>&1); assert_eq "$?" "0" "malformed stdin: allowed" || rc=1
  out=$(printf '{}' | bash "$GNM_HOOK" 2>&1); assert_eq "$?" "0" "no command: allowed" || rc=1
  gnm_allowed "unbalanced quote, no milestone" "echo 'deliver.sh status" || rc=1
  gnm_blocked "unbalanced quote, milestone register" "skills/orchestrate/deliver.sh a/b:milestone:5 'unterminated" || rc=1
  return $rc
}

test_gnm_hook_honours_the_legacy_override_from_its_own_environment_only() {
  local rc=0 in
  in=$(jq -nc '{tool_name:"Bash", tool_input:{command:"skills/orchestrate/deliver.sh a/b:milestone:5"}}')
  printf '%s' "$in" | GOAL_ALLOW_LEGACY_REGISTER=1 bash "$GNM_HOOK" >/dev/null 2>&1
  assert_eq "$?" "0" "override in the hook's environment: allowed" || rc=1
  return $rc
}

# ---------------------------------------------------------------- deliver.sh ----------------------------------------------

# gnm_run <deliver.sh args> — deliver.sh with the override unset (run-tests.sh exports it for the other suites)
gnm_run() {
  local keep=${GOAL_ALLOW_LEGACY_REGISTER-__unset__}
  unset GOAL_ALLOW_LEGACY_REGISTER
  dg_run "$@"
  [ "$keep" = __unset__ ] || export GOAL_ALLOW_LEGACY_REGISTER=$keep
}

test_gnm_deliver_refuses_a_new_non_project_goal_without_touching_anything() {
  dg_setup
  local rc=0
  gnm_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "1" "milestone goal: refused" || rc=1
  assert_contains "$DG_ERR" "$GNM_HINT" "names the project form" || rc=1
  assert_contains "$DG_ERR" "gh project create" "names how to create the project" || rc=1
  assert_contains "$DG_ERR" "GOAL_ALLOW_LEGACY_REGISTER" "names the legacy override" || rc=1
  assert_eq "$(dg_reg_count)" "0" "no registry issue" || rc=1
  assert_eq "$(dg_writes)" "0" "nothing written to GitHub" || rc=1
  gnm_run "$DG_SPEC_ALL"
  assert_eq "$DG_RC" "1" "milestones:all goal: refused" || rc=1
  assert_contains "$DG_ERR" "$GNM_HINT" "msall: names the project form" || rc=1
  assert_eq "$(dg_reg_count)" "0" "msall: no registry issue" || rc=1
  assert_eq "$(dg_writes)" "0" "msall: nothing written to GitHub" || rc=1
  gnm_run "$DG_SPEC_MS" --now --priority 1 "some instructions"
  assert_eq "$DG_RC" "1" "with flags: refused" || rc=1
  gnm_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "1" "ticket goal: refused" || rc=1
  assert_contains "$DG_ERR" "$GNM_HINT" "ticket goal: names the project form" || rc=1
  gnm_run "example-owner/project-a:feedback"   # the fixture has no user-feedback ticket: it gets past both refusals and stops at the empty scope
  assert_not_contains "$DG_ERR" "$GNM_HINT" "feedback goal: not refused as a non-project goal" || rc=1
  assert_not_contains "$DG_ERR" "go true or go false" "feedback goal: no go question (it has no go field)" || rc=1
  assert_contains "$DG_ERR" "empty scope" "feedback goal: reaches the scope check" || rc=1
  gnm_run "label:Q4" --repos example-owner/project-a --title Q4
  assert_eq "$DG_RC" "1" "label goal: refused" || rc=1
  gnm_run --repos example-owner/project-a --title Q4
  assert_eq "$DG_RC" "1" "label goal by --repos/--title alone: refused" || rc=1
  assert_contains "$DG_ERR" "$GNM_HINT" "label goal: names the project form" || rc=1
  assert_eq "$(dg_reg_count)" "0" "none of them wrote a registry issue" || rc=1
  assert_eq "$(dg_writes)" "0" "none of them wrote to GitHub" || rc=1
  gnm_run register "$DG_SPEC_MS"
  assert_ne "$DG_RC" "0" "the literal word register before a milestone spec does not register it" || rc=1
  assert_eq "$(dg_reg_count)" "0" "still no registry issue" || rc=1
  dg_teardown; return $rc
}

test_gnm_deliver_override_env_still_registers_a_legacy_goal_for_legacy_tooling() {
  dg_setup
  local rc=0 keep=${GOAL_ALLOW_LEGACY_REGISTER-__unset__}
  export GOAL_ALLOW_LEGACY_REGISTER=1
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "override set: registers (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "one registry issue" || rc=1
  if [ "$keep" = __unset__ ]; then unset GOAL_ALLOW_LEGACY_REGISTER; else export GOAL_ALLOW_LEGACY_REGISTER=$keep; fi
  gnm_run "$DG_SPEC_ALL"
  assert_eq "$DG_RC" "1" "the override is read from the environment of the call, not remembered" || rc=1
  dg_teardown; return $rc
}

test_gnm_deliver_override_must_be_exactly_1() {
  dg_setup
  local rc=0 v
  for v in 0 yes true ""; do
    dg_setup_noop=1
    ( unset GOAL_ALLOW_LEGACY_REGISTER; export GOAL_ALLOW_LEGACY_REGISTER="$v"; dg_run "$DG_SPEC_MS"; echo "$DG_RC" > "$DG_HOME/rc" )
    assert_eq "$(cat "$DG_HOME/rc")" "1" "override='$v' is not the override" || rc=1
  done
  assert_eq "$(dg_reg_count)" "0" "nothing registered" || rc=1
  dg_teardown; return $rc
}

test_gnm_deliver_refusal_text_does_not_hit_the_project_form() {
  dg_setup
  local rc=0
  gnm_run "project:example-owner/12" --go --priority 1
  assert_not_contains "$DG_ERR" "GOAL_ALLOW_LEGACY_REGISTER" "a project spec is never told about the legacy override" || rc=1
  gnm_run "example-owner/project-a:project:12" --no-go --priority 1
  assert_not_contains "$DG_ERR" "GOAL_ALLOW_LEGACY_REGISTER" "the repo alias form neither" || rc=1
  dg_teardown; return $rc
}

test_gnm_deliver_existing_milestone_goals_keep_working_with_the_override_off() {
  dg_setup
  local rc=0 id keep=${GOAL_ALLOW_LEGACY_REGISTER-__unset__}
  export GOAL_ALLOW_LEGACY_REGISTER=1
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "seed: legacy register (stderr: $DG_ERR)" || rc=1
  unset GOAL_ALLOW_LEGACY_REGISTER
  gnm_run status
  assert_eq "$DG_RC" "0" "status (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "$DG_ID_MS" "status lists the milestone goal" || rc=1
  gnm_run stop "$DG_ID_MS"
  assert_eq "$DG_RC" "0" "stop (stderr: $DG_ERR)" || rc=1
  gnm_run release "$DG_ID_MS"
  assert_eq "$DG_RC" "0" "release (stderr: $DG_ERR)" || rc=1
  gnm_run resume "$DG_ID_MS"
  assert_eq "$DG_RC" "0" "resume (stderr: $DG_ERR)" || rc=1
  gnm_run priority "$DG_ID_MS" 1
  assert_eq "$DG_RC" "0" "priority (stderr: $DG_ERR)" || rc=1
  assert_not_contains "$DG_ERR" "$GNM_HINT" "none of them prints the refusal" || rc=1
  if [ "$keep" = __unset__ ]; then unset GOAL_ALLOW_LEGACY_REGISTER; else export GOAL_ALLOW_LEGACY_REGISTER=$keep; fi   # leave the shared environment as found
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- naming convention ----------------------------------------------

test_gnm_hook_blocks_goal_project_titles_that_break_the_naming_convention() {
  local rc=0 t
  gnm_blocked "double prefix" 'gh project create --owner Benjis-Plants --title "Goal: Goal: CD release hardening"' || rc=1
  gnm_blocked "repo path" 'gh project create --owner Benjis-Plants --title "Goal: Benjis-Plants/benjis-sales-tool:feedback"' || rc=1
  gnm_blocked "ticket reference on edit" 'gh project edit 40 --owner Benjis-Plants --title "Goal: feedback for #1153"' || rc=1
  gnm_blocked "--title= form" 'gh project edit 40 --owner Benjis-Plants --title="Goal: a/b"' || rc=1
  gnm_blocked "wrong prefix spelling" 'gh project create --owner Benjis-Plants --title "goal: Sales Workflow 3.0"' || rc=1
  gnm_blocked "no name" 'gh project create --owner Benjis-Plants --title "Goal: "' || rc=1
  gnm_blocked "over ssh" "ssh clog-exec 'gh project create --owner Benjis-Plants --title \"Goal: Goal: x\"'" || rc=1
  gnm_allowed "a good name" 'gh project create --owner Benjis-Plants --title "Goal: Ops Sentry goal"' || rc=1
  gnm_allowed "apostrophe and digits" "gh project edit 40 --owner Benjis-Plants --title \"Goal: Benji's Sales Tool feedback\"" || rc=1
  gnm_allowed "version in the name" 'gh project edit 44 --owner Benjis-Plants --title "Goal: Sales Workflow 3.0"' || rc=1
  gnm_allowed "a project that is not a goal" 'gh project create --owner Benjis-Plants --title "Backlog"' || rc=1
  gnm_allowed "other gh project subcommands" 'gh project item-add 40 --owner Benjis-Plants --url https://github.com/a/b/issues/3' || rc=1
  gnm_allowed "list" 'gh project list --owner Benjis-Plants' || rc=1
  return $rc
}

# gnm_lib '<snippet>' — runs a goal-lib snippet in the sandbox, DG_OUT / DG_RC
test_gnm_name_helpers_build_and_check_the_one_name() {
  dg_setup
  local rc=0
  dg_lib 'goal_title "Ops Sentry goal"'; assert_eq "$DG_OUT" "Goal: Ops Sentry goal" "goal_title adds exactly one prefix" || rc=1
  dg_lib 'goal_name_of_title "Goal: Goal: benjis-ops-tool: CD release hardening"'; assert_eq "$DG_OUT" "benjis-ops-tool: CD release hardening" "every leading Goal: is removed" || rc=1
  dg_lib 'goal_name_of_title "Sales Workflow 3.0"'; assert_eq "$DG_OUT" "Sales Workflow 3.0" "a title without the prefix is its own name" || rc=1
  dg_lib 'goal_name_of_title "Goal: Benji'"'"'s Ops Tool feedback  "'; assert_eq "$DG_OUT" "Benji's Ops Tool feedback" "trailing space trimmed" || rc=1
  local good bad
  for good in "Goal: Ops Sentry goal" "Goal: Sales Workflow 3.0" "Goal: Benji's Sales Tool feedback" "Goal: CD release hardening"; do
    dg_lib "goal_title_check \"$good\""; assert_eq "$DG_RC" "0" "accepted: $good" || rc=1
  done
  for bad in "Ops Sentry goal" "goal: Ops Sentry goal" "Goal: " "Goal: Goal: Ops" "Goal:  Ops" "Goal: Ops " "Goal: example-owner/project-a:feedback" \
             "Goal: ticket #12" "Goal: label:foo" "Goal: x:milestone:3" "Goal: $(printf 'x%.0s' $(seq 1 81))"; do
    dg_lib "goal_title_check \"$bad\""; assert_eq "$DG_RC" "1" "refused: $bad" || rc=1
  done
  dg_lib 'goal_title_check "Goal: Goal: Ops"'; assert_contains "$DG_ERR" "repeats" "the reason names the double prefix" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- docs and wiring ----------------------------------------------

test_gnm_hook_text_and_deliver_text_say_the_same_thing() {
  local rc=0 phrase
  for phrase in 'project:<owner>/<n>' 'gh project create' 'gh project item-add' '<short human name>'; do
    assert_contains "$(cat "$GNM_HOOK")" "$phrase" "hook carries: $phrase" || rc=1
    assert_contains "$(cat "$GNM_ROOT/skills/orchestrate/goal-lib.sh")" "$phrase" "goal-lib carries: $phrase" || rc=1
  done
  return $rc
}

test_gnm_settings_wires_the_hook_on_bash_pretooluse() {
  local n
  n=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/hooks/block-nonproject-goal.sh"))] | length' "$GNM_ROOT/settings.json")
  assert_eq "$n" "1" "settings.json: PreToolUse Bash runs block-nonproject-goal.sh exactly once"
}

test_gnm_docs_describe_the_right_way_to_register_a_goal() {
  local rc=0 skill readme
  skill=$(cat "$GNM_ROOT/skills/orchestrate/SKILL.md"); readme=$(cat "$GNM_ROOT/README.md")
  assert_contains "$skill" "gh project create --owner Benjis-Plants" "SKILL.md: create the project" || rc=1
  assert_contains "$skill" "gh project item-add" "SKILL.md: add the tickets" || rc=1
  assert_contains "$skill" "deliver.sh project:Benjis-Plants/" "SKILL.md: register the project" || rc=1
  assert_contains "$skill" "GOAL_ALLOW_LEGACY_REGISTER" "SKILL.md: the legacy override" || rc=1
  assert_contains "$skill" 'Goal: <short human name>' "SKILL.md: the naming convention" || rc=1
  assert_contains "$skill" 'ask JP: go true or go false?' "SKILL.md: the go question" || rc=1
  assert_contains "$skill" 'may never pick it itself' "SKILL.md: the session never picks go" || rc=1
  assert_contains "$skill" 'Priority only orders the queue.' "SKILL.md: priority does not preempt" || rc=1
  assert_contains "$skill" 'is optional' "SKILL.md: priority is optional" || rc=1
  assert_not_contains "$skill" 'ask JP for the priority' "SKILL.md: no priority prompt" || rc=1
  assert_contains "$readme" "hooks/block-nonproject-goal.sh" "README lists the hook" || rc=1
  return $rc
}

for t in test_gnm_hook_exists_and_is_executable_bash \
         test_gnm_hook_blocks_milestone_registration_in_every_shape \
         test_gnm_hook_names_the_whole_recipe \
         test_gnm_hook_lets_other_subcommands_and_goal_forms_through \
         test_gnm_hook_ignores_text_that_only_mentions_deliver_sh \
         test_gnm_hook_never_wedges_on_odd_input \
         test_gnm_hook_honours_the_legacy_override_from_its_own_environment_only \
         test_gnm_deliver_refuses_a_new_non_project_goal_without_touching_anything \
         test_gnm_deliver_override_env_still_registers_a_legacy_goal_for_legacy_tooling \
         test_gnm_deliver_override_must_be_exactly_1 \
         test_gnm_deliver_refusal_text_does_not_hit_the_project_form \
         test_gnm_deliver_existing_milestone_goals_keep_working_with_the_override_off \
         test_gnm_hook_blocks_a_project_registration_that_omits_the_go_choice \
         test_gnm_hook_does_not_require_a_priority \
         test_gnm_hook_blocks_goal_project_titles_that_break_the_naming_convention \
         test_gnm_name_helpers_build_and_check_the_one_name \
         test_gnm_hook_text_and_deliver_text_say_the_same_thing \
         test_gnm_settings_wires_the_hook_on_bash_pretooluse \
         test_gnm_docs_describe_the_right_way_to_register_a_goal; do
  run_test "$t"
done
