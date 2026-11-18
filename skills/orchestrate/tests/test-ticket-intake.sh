# JP, 2026-11-18: every time JP asks for a ticket (or something done through the pipeline), a hook triggers the ticket-intake skill,
# which puts the ticket in a registered goal's project and gives it agent-go; a PreToolUse guard refuses a bare `gh issue create`
# on the application repos. Covers hooks/ticket-intake-reminder.sh + hooks/ticket-intent-patterns.txt (UserPromptSubmit),
# hooks/ticket-intake-guard.sh (PreToolUse), skills/ticket-intake/ticket-intake.sh (goals / finish) and the wiring/docs, offline,
# against a fake `gh` serving a fixture goal registry. Prefix ti_ / TI_.

HERE_TI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_TI=$(cd "$HERE_TI/../../.." && pwd)
REM_TI="$ROOT_TI/hooks/ticket-intake-reminder.sh"
GUARD_TI="$ROOT_TI/hooks/ticket-intake-guard.sh"
PATS_TI="$ROOT_TI/hooks/ticket-intent-patterns.txt"
HELPER_TI="$ROOT_TI/skills/ticket-intake/ticket-intake.sh"
SKILL_TI="$ROOT_TI/skills/ticket-intake/SKILL.md"
DEDUPE_TI="$ROOT_TI/hooks/dedupe-ticket-guard.sh"

OPS_TI="Benjis-Plants/benjis-ops-tool"
SALES_TI="Benjis-Plants/benjis-sales-tool"

ti_setup() {  # scratch dir TI_D with a fake gh serving the registry fixture + a per-case issue fixture
  TI_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ti.XXXXXX")
  mkdir -p "$TI_D/bin"
  python3 - "$TI_D/registry.json" <<'PY'
import json, sys
def goal(n, title, block, labels=("delivery-goal",)):
    body = "Registry.\n\n```json\n" + json.dumps(block) + "\n```\n"
    return {"number": n, "title": title, "body": body, "state": "open", "labels": [{"name": l} for l in labels]}
sp = lambda o, n: {"owner": o, "number": n, "url": "https://github.com/users/%s/projects/%d" % (o, n)}
items = [
  goal(759, "Goal: CD release hardening", {"v": 2, "id": "proj-jpmoya_41", "repos": ["Benjis-Plants/benjis-ops-tool"], "go": True, "spec": "project:jpmoya/41", "scope_project": sp("jpmoya", 41)}),
  goal(705, "Goal: Sales Workflow 3.0", {"v": 2, "id": "proj-jpmoya_44", "repos": ["Benjis-Plants/benjis-sales-tool", "Benjis-Plants/benjis-ops-tool"], "go": False, "spec": "project:jpmoya/44", "scope_project": sp("jpmoya", 44)}),
  goal(538, "Goal: Benji's Sales Tool feedback", {"v": 1, "id": "fb-sales", "spec": "Benjis-Plants/benjis-sales-tool:feedback", "project": sp("jpmoya", 40)}),
  goal(537, "Goal: Benji's Ops Tool feedback", {"v": 1, "id": "fb-ops", "spec": "Benjis-Plants/benjis-ops-tool:feedback", "project": sp("jpmoya", 37)}),
  goal(600, "Goal: Stopped One", {"v": 2, "id": "proj-jpmoya_50", "repos": ["Benjis-Plants/benjis-ops-tool"], "spec": "project:jpmoya/50", "scope_project": sp("jpmoya", 50)}, ("delivery-goal", "goal-stopped")),
  goal(610, "Goal: Old label goal", {"v": 2, "id": "label-x", "repos": ["Benjis-Plants/benjis-ops-tool"], "spec": "label:goal: X", "label": "goal: X"}),
]
json.dump(items, open(sys.argv[1], "w"))
PY
  ti_issue OPEN ""
  cat > "$TI_D/bin/gh" <<GHEOF
#!/bin/bash
# Fake gh for test-ticket-intake.sh: registry fixture, per-case issue fixture, write log, failure switches.
printf '%s\n' "\$*" >> "$TI_D/gh.log"
case "\$*" in
  "api -X GET repos/jpmoya/claude-agents/issues"*) cat "$TI_D/registry.json" ;;
  "issue view "*--json\ state,labels,url) cat "$TI_D/issue.json" ;;
  "project item-add "*) [ -e "$TI_D/fail-project" ] && { echo "missing project scope" >&2; exit 1; }; echo '{}' ;;
  "issue edit "*) [ -e "$TI_D/fail-label" ] && { echo "label failure" >&2; exit 1; }; : ;;
  *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
GHEOF
  chmod +x "$TI_D/bin/gh"
  TI_OLDPATH=$PATH; PATH="$TI_D/bin:$PATH"
  export TICKET_INTAKE_LOG="$TI_D/intake.log"
}
ti_teardown() { PATH=$TI_OLDPATH; rm -rf "$TI_D"; unset TICKET_INTAKE_LOG; }

# ti_issue <state> <labels comma list>  -> the fake `gh issue view --json state,labels,url` answer (projectItems is deliberately never requested)
ti_issue() {
  python3 - "$TI_D/issue.json" "$1" "$2" <<'PY'
import json, sys
out, state, labels = sys.argv[1:4]
json.dump({"state": state, "url": "https://github.com/Benjis-Plants/benjis-ops-tool/issues/77",
           "labels": [{"name": l} for l in labels.split(",") if l]}, open(out, "w"))
PY
}
ti_writes() { grep -E '^(project item-add|issue edit)' "$TI_D/gh.log" 2>/dev/null; }
ti_fin() { TI_OUT=$("$HELPER_TI" finish "$@" 2>&1); TI_RC=$?; }

# ------------------------------------------------------------------ reminder hook (UserPromptSubmit) ----------------
ti_rem() {  # ti_rem <prompt> [field] -> TI_OUT = stdout; returns the hook's exit code
  local field=${2:-prompt} input rc
  input=$(python3 -c 'import json,sys; print(json.dumps({sys.argv[2]: sys.argv[1], "hook_event_name": "UserPromptSubmit"}))' "$1" "$field")
  TI_OUT=$(printf '%s' "$input" | env -u PIPELINE_AGENT bash "$REM_TI" 2>&1); rc=$?
  return "$rc"
}

test_ti_reminder_fires_on_every_ticket_request_phrasing() {
  local p rc=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ti_rem "$p"; assert_eq "$?" "0" "never blocks the prompt: $p" || rc=1
    assert_contains "$TI_OUT" "ticket-intake" "fires on: $p" || rc=1
  done <<'EOP'
log a ticket for the duplicate invoice bug
Please file a bug: the schedule page shows the wrong week
can you create a ticket for this
open an issue about the export button
raise a ticket on the quoting tool
I want a ticket logged for the login loop
write me a ticket for this
add this to the backlog
put it on the board
track this please
make this a ticket
turn this into a story
log this bug in the ops tool
file an issue for the sales tool
Found a bug in the timesheet screen, the totals are off
bug: technicians cannot check out on iOS
we need a ticket for the Copper sync
get the agents to fix the checkout note
send this through the pipeline
I have a feature request: dark mode in the tech app
Ticket this
Create a new ticket: rename the Visits tab
EOP
  return $rc
}

test_ti_reminder_stays_quiet_on_non_requests() {
  local p rc=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ti_rem "$p"; assert_eq "$?" "0" "exit 0: $p" || rc=1
    assert_eq "$TI_OUT" "" "quiet on: $p" || rc=1
  done <<'EOP'
list the open issues
what is the status of ticket #1840
close the ticket once the PR merges
check the logs for the failed run
the log file is empty
open the file hooks/limit-shells.sh
file upload bug in the old form, how does it behave
I have an issue with my login
what is the issue with this deploy
create a task runner script
create a table for visits
open issues older than 30 days
show me the ticket
how many bugs are open
log in to Vercel
good morning
EOP
  return $rc
}

test_ti_reminder_reads_all_three_field_names_and_skips_pipeline_agents() {
  local rc=0 input
  ti_rem "log a ticket for this" prompt;      assert_contains "$TI_OUT" "ticket-intake" "field prompt (documented name)" || rc=1
  ti_rem "log a ticket for this" user_prompt;  assert_contains "$TI_OUT" "ticket-intake" "field user_prompt" || rc=1
  ti_rem "log a ticket for this" message;      assert_contains "$TI_OUT" "ticket-intake" "field message" || rc=1
  input='{"prompt":"log a ticket for this"}'
  TI_OUT=$(printf '%s' "$input" | PIPELINE_AGENT=product-manager bash "$REM_TI" 2>&1); assert_eq "$TI_OUT" "" "silent for pipeline stage processes" || rc=1
  TI_OUT=$(printf 'not json' | env -u PIPELINE_AGENT bash "$REM_TI" 2>&1); assert_eq "$?" "0" "garbage input exits 0" || rc=1
  assert_eq "$TI_OUT" "" "garbage input is silent" || rc=1
  return $rc
}

test_ti_reminder_output_is_hook_json_with_the_hard_instruction() {
  local rc=0 ctx
  ti_rem "please log a bug for X"
  assert_eq "$(printf '%s' "$TI_OUT" | jq -r .hookSpecificOutput.hookEventName)" "UserPromptSubmit" "event name" || rc=1
  ctx=$(printf '%s' "$TI_OUT" | jq -r .hookSpecificOutput.additionalContext)
  assert_contains "$ctx" "REQUIRED, before anything else" "hard instruction" || rc=1
  assert_contains "$ctx" "skills/ticket-intake/SKILL.md" "names the skill" || rc=1
  assert_contains "$ctx" "~/.claude/skills/ticket-intake/SKILL.md" "absolute skill path (resolves from any checkout)" || rc=1
  assert_contains "$ctx" "jpmoya/claude-agents repo is exempt" "tells about the direct-route exemption" || rc=1
  return $rc
}

test_ti_pattern_list_lives_in_one_file() {
  local rc=0 custom
  assert_file_exists "$PATS_TI" || rc=1
  assert_not_contains "$(cat "$REM_TI")" "throw" "the hook script carries no pattern of its own" || rc=1
  assert_ne "$(grep -cvE '^[[:space:]]*(#|$)' "$PATS_TI")" "0" "patterns present" || rc=1
  TI_OUT=$(printf '%s' '{"prompt":"log a ticket"}' | env -u PIPELINE_AGENT TICKET_INTENT_PATTERNS="$HERE_TI/does-not-exist.txt" bash "$REM_TI" 2>&1)
  assert_eq "$TI_OUT" "" "a missing patterns file fails quiet (never blocks)" || rc=1
  custom=$(mktemp "${TMPDIR:-/tmp}/ti-pat.XXXXXX"); printf '%s\n' '\bzebra\b' > "$custom"
  TI_OUT=$(printf '%s' '{"prompt":"a zebra please"}' | env -u PIPELINE_AGENT TICKET_INTENT_PATTERNS="$custom" bash "$REM_TI" 2>&1)
  assert_contains "$TI_OUT" "ticket-intake" "the list is read from the file (override works)" || rc=1
  rm -f "$custom"
  return $rc
}

# ------------------------------------------------------------------ PreToolUse guard ---------------------------------
ti_guard() {  # ti_guard <command> [extra env...] -> TI_OUT = stderr; returns the hook's exit code
  local input rc cmd=$1
  shift
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$cmd" "$TI_D")
  TI_OUT=$(printf '%s' "$input" | env -u PIPELINE_AGENT TICKET_INTAKE_LOG="$TI_D/guard.log" TICKET_INTAKE_CONFIG="$TI_D/none.sh" ${1+"$@"} bash "$GUARD_TI" 2>&1 >/dev/null)
  rc=$?
  return "$rc"
}

test_ti_guard_refuses_a_bare_create_on_application_repos() {
  ti_setup
  local rc=0
  ti_guard "gh issue create -R $OPS_TI --title 'Fix X' --body 'Why: y'"; assert_eq "$?" "2" "bare create on the ops tool is refused" || rc=1
  assert_contains "$TI_OUT" "Intake: project=" "message names the marker" || rc=1
  assert_contains "$TI_OUT" "ticket-intake.sh goals" "message names the helper" || rc=1
  ti_guard "gh issue create --repo $SALES_TI --title T --body B"; assert_eq "$?" "2" "sales tool refused" || rc=1
  ti_guard "gh api repos/$OPS_TI/issues -f title=T -f body=B"; assert_eq "$?" "2" "issues POST via gh api refused" || rc=1
  ti_guard "gh api -X POST repos/$OPS_TI/issues -f title=T"; assert_eq "$?" "2" "explicit POST refused" || rc=1
  ti_guard "curl -s -X POST https://api.github.com/repos/$OPS_TI/issues -d '{\"title\":\"T\"}'"; assert_eq "$?" "2" "curl POST refused" || rc=1
  ti_guard "gh api graphql -f query='mutation { createIssue(input:{repositoryId:\"R\",title:\"T\"}) { issue { id } } }'"; assert_eq "$?" "2" "GraphQL createIssue refused" || rc=1
  ti_guard "gh issue create -R Benjis-Plants/scheduler --title T --body B"; assert_eq "$?" "2" "the old name of the ops tool (scheduler) is the ops tool" || rc=1
  ti_guard "gh issue create -R Benjis-Plants/benjis-quoting-tool --title T --body B"; assert_eq "$?" "2" "the old name of the sales tool is the sales tool" || rc=1
  ti_guard "gh issue create -R Benjis-Plants/scheduler --title T --body 'Intake: project=none'"; assert_eq "$?" "0" "old name + marker passes" || rc=1
  assert_contains "$(cat "$TI_D/guard.log")" '"outcome": "blocked"' "refusal logged" || rc=1
  ti_teardown; return $rc
}

test_ti_guard_accepts_the_intake_marker_in_every_place_it_can_live() {
  ti_setup
  local rc=0
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Why: y
Intake: project=jpmoya/41'"; assert_eq "$?" "0" "marker in --body (goal project)" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Intake: project=none'"; assert_eq "$?" "0" "project=none (standalone) is a decision too" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body-file - <<'HEREDOC'
Why: y
Intake: project=jpmoya/44
HEREDOC"; assert_eq "$?" "0" "marker in a heredoc body" || rc=1
  printf 'Why: y\nIntake: project=jpmoya/41\n' > "$TI_D/body.md"
  ti_guard "gh issue create -R $OPS_TI --title T --body-file $TI_D/body.md"; assert_eq "$?" "0" "marker in --body-file" || rc=1
  ti_guard "# Intake: project=none
gh issue create -R $OPS_TI --title T --body B"; assert_eq "$?" "0" "marker in a shell comment" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body B --project 'Goal: CD release hardening'"; assert_eq "$?" "0" "gh's own --project flag counts as the decision" || rc=1
  ti_guard "gh api repos/$OPS_TI/issues -f title=T -f body='Intake: project=jpmoya/41'"; assert_eq "$?" "0" "marker in an API body field" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Intake: project=banana'"; assert_eq "$?" "2" "a malformed marker is not accepted" || rc=1
  ti_teardown; return $rc
}

test_ti_guard_go_no_needs_a_reason() {
  ti_setup
  local rc=0
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Intake: project=none go=no'"; assert_eq "$?" "2" "go=no without a reason is refused" || rc=1
  assert_contains "$TI_OUT" "needs a reason" "says why" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Intake: project=none go=no — fix already shipped by a bypass pipeline hotfix, history only'"; assert_eq "$?" "0" "go=no with a reason passes" || rc=1
  assert_contains "$(cat "$TI_D/guard.log")" '"go_no": true' "go=no is logged" || rc=1
  ti_teardown; return $rc
}

ti_guard_with_transcript() {  # <agentSetting> -> returns the guard's exit code for a bare create from a session whose transcript names that agent
  local tr="$TI_D/transcript.jsonl" rc
  printf '{"agentSetting":"%s"}\n{"x":1}\n' "$1" > "$tr"
  printf '%s' "{\"tool_input\":{\"command\":\"gh issue create -R $OPS_TI --title T --body B\"},\"cwd\":\"$TI_D\",\"transcript_path\":\"$tr\"}" \
    | env -u PIPELINE_AGENT TICKET_INTAKE_LOG="$TI_D/g.log" TICKET_INTAKE_CONFIG="$TI_D/none.sh" bash "$GUARD_TI" >/dev/null 2>&1
  return $?
}

test_ti_guard_exemptions() {
  ti_setup
  local rc=0
  ti_guard "gh issue create -R jpmoya/claude-agents --title T --body B"; assert_eq "$?" "0" "direct-route repo: no project, no agent-go, never enforced" || rc=1
  ti_guard "gh issue create -R JPMoya/Claude-Agents --title T --body B"; assert_eq "$?" "0" "direct-route match is case-insensitive" || rc=1
  ti_guard "gh issue create -R someone/else --title T --body B"; assert_eq "$?" "0" "a repo outside the application set is not enforced" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body B" PIPELINE_AGENT=product-manager; assert_eq "$?" "0" "pipeline stage processes file under their own rules" || rc=1
  ti_guard_with_transcript delivery-lead; assert_eq "$?" "0" "a delivery-lead session is exempt" || rc=1
  ti_guard_with_transcript orchestrator; assert_eq "$?" "0" "an orchestrator session is exempt" || rc=1
  ti_guard_with_transcript general-purpose; assert_eq "$?" "2" "any other session is enforced" || rc=1
  ti_teardown; return $rc
}

test_ti_guard_ignores_everything_that_is_not_a_create() {
  ti_setup
  local rc=0 c
  for c in "gh issue view 12 -R $OPS_TI" "gh issue edit 12 -R $OPS_TI --add-label agent-go" "gh issue list -R $OPS_TI" "gh pr create --title 'gh issue create docs' --body B" \
           "grep -n 'gh issue create' README.md" "git commit -m 'document gh issue create'" "gh api repos/$OPS_TI/issues/12" "gh api repos/$OPS_TI/issues/12/comments -f body=hi" \
           "gh issue create --help" "echo hello"; do
    ti_guard "$c"; assert_eq "$?" "0" "not a create: $c" || rc=1
  done
  ti_teardown; return $rc
}

test_ti_guard_enforced_set_follows_config_local() {
  ti_setup
  local rc=0 cfg="$TI_D/config.local.sh"
  cat > "$cfg" <<'CFGEOF'
DISPATCH_REPOS=(
  # "Benjis-Plants/commented-out:$HOME/dev/x"
  "Benjis-Plants/benjis-ops-tool:$HOME/dev/benjis-ops-tool"
  "Acme/extra-app:$HOME/dev/extra-app"
)
DISPATCH_REPOS+=("Acme/second-app:$HOME/dev/second-app")
# 2026-11-09 JP: direct-route. was: DISPATCH_REPOS+=("jpmoya/claude-agents:$HOME/dev/claude-agents")
SCAN_ONLY_REPOS=("Acme/scan-only")
CFGEOF
  ti_guard "gh issue create -R Acme/extra-app --title T --body B" TICKET_INTAKE_CONFIG="$cfg"; assert_eq "$?" "2" "a DISPATCH_REPOS entry is enforced" || rc=1
  ti_guard "gh issue create -R Acme/second-app --title T --body B" TICKET_INTAKE_CONFIG="$cfg"; assert_eq "$?" "2" "a DISPATCH_REPOS+= entry is enforced" || rc=1
  ti_guard "gh issue create -R Acme/scan-only --title T --body B" TICKET_INTAKE_CONFIG="$cfg"; assert_eq "$?" "2" "a SCAN_ONLY_REPOS entry is enforced" || rc=1
  ti_guard "gh issue create -R Benjis-Plants/commented-out --title T --body B" TICKET_INTAKE_CONFIG="$cfg"; assert_eq "$?" "0" "a commented-out entry is not" || rc=1
  ti_guard "gh issue create -R jpmoya/claude-agents --title T --body B" TICKET_INTAKE_CONFIG="$cfg"; assert_eq "$?" "0" "the commented direct-route entry stays exempt" || rc=1
  ti_guard "gh issue create -R Acme/extra-app --title T --body B" TICKET_INTAKE_CONFIG="$cfg" TICKET_INTAKE_DIRECT_ROUTE="Acme/extra-app"; assert_eq "$?" "0" "a direct-route repo wins over the dispatch list" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body B" TICKET_INTAKE_CONFIG="$TI_D/missing.sh"; assert_eq "$?" "2" "a missing config falls back to the built-in list" || rc=1
  ti_teardown; return $rc
}

ti_dedupe_rc() {  # <command> -> exit code of the dedupe guard with a find-duplicates stub that reports no candidate
  local input
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$TI_D")
  printf '%s' "$input" | env -u PIPELINE_AGENT DEDUPE_FIND_CMD="$TI_D/find-none" DEDUPE_GUARD_LOG="$TI_D/dd.log" bash "$DEDUPE_TI" >/dev/null 2>&1
}

test_ti_guard_and_dedupe_guard_are_independent() {
  ti_setup
  local rc=0 cmd_both cmd_bare
  printf '#!/bin/bash\nexit 0\n' > "$TI_D/find-none"; chmod +x "$TI_D/find-none"
  cmd_both="gh issue create -R $OPS_TI --title 'Fix the thing today' --body 'Intake: project=jpmoya/41'"
  cmd_bare="gh issue create -R $OPS_TI --title 'Fix the thing today' --body 'Why: y'"
  ti_dedupe_rc "$cmd_both"; assert_eq "$?" "0" "dedupe guard passes a command that carries the Intake line (no candidates)" || rc=1
  ti_guard "$cmd_both"; assert_eq "$?" "0" "intake guard passes it too" || rc=1
  ti_dedupe_rc "$cmd_bare"; assert_eq "$?" "0" "dedupe guard has no opinion on the project/agent-go decision" || rc=1
  ti_guard "$cmd_bare"; assert_eq "$?" "2" "intake guard refuses the bare create on its own" || rc=1
  assert_not_contains "$TI_OUT" "DUPLICATE CHECK" "the two refusals read differently" || rc=1
  ti_guard "gh issue create -R $OPS_TI --title T --body 'Dup-check: reviewed #1 — differs because reasons given here'"; assert_eq "$?" "2" "a Dup-check line is not an Intake line" || rc=1
  ti_teardown; return $rc
}

# ------------------------------------------------------------------ helper: goals ------------------------------------
test_ti_goals_lists_only_open_project_goals_that_fit_the_repo() {
  ti_setup
  local rc=0 out
  out=$("$HELPER_TI" goals "$OPS_TI" 2>&1)
  assert_contains "$out" "jpmoya/41	CD release hardening	go=true	https://github.com/users/jpmoya/projects/41" "ops goal with go and url" || rc=1
  assert_contains "$out" "jpmoya/44	Sales Workflow 3.0	go=false" "go-false goal is listed with go=false" || rc=1
  assert_not_contains "$out" "jpmoya/40" "the sales feedback goal's mirror project is not a choice" || rc=1
  assert_not_contains "$out" "jpmoya/37" "the ops feedback goal's mirror project is not a choice" || rc=1
  assert_not_contains "$out" "jpmoya/50" "a stopped goal is not a choice" || rc=1
  assert_not_contains "$out" "Old label goal" "a label goal is not project-scoped" || rc=1
  out=$("$HELPER_TI" goals "$SALES_TI" 2>&1)
  assert_contains "$out" "jpmoya/44" "sales repo: the cross-repo project" || rc=1
  assert_not_contains "$out" "jpmoya/41" "sales repo: the ops-only project is filtered out" || rc=1
  out=$("$HELPER_TI" goals Benjis-Plants/scheduler 2>&1); assert_contains "$out" "jpmoya/41" "old repo name resolves to the ops tool's goals" || rc=1
  out=$("$HELPER_TI" goals Benjis-Plants/other-app 2>&1); assert_contains "$out" "the answer is none" "no fit: says none" || rc=1
  out=$("$HELPER_TI" goals jpmoya/claude-agents 2>&1); assert_eq "$?" "0" "direct-route repo: exit 0" || rc=1
  assert_contains "$out" "direct-route" "direct-route repo: nothing to choose" || rc=1
  assert_not_contains "$out" "jpmoya/41" "direct-route repo: no project offered" || rc=1
  ti_teardown; return $rc
}

# ------------------------------------------------------------------ helper: finish -----------------------------------
test_ti_finish_adds_to_the_project_and_agent_go_then_is_idempotent() {
  ti_setup
  local rc=0
  ti_fin "$OPS_TI" 77 --project jpmoya/41
  assert_eq "$TI_RC" "0" "finish exits 0 ($TI_OUT)" || rc=1
  assert_contains "$(ti_writes)" "project item-add 41 --owner jpmoya --url https://github.com/Benjis-Plants/benjis-ops-tool/issues/77" "project item-add with the issue URL" || rc=1
  assert_contains "$(ti_writes)" "issue edit 77 -R $OPS_TI --add-label agent-go" "agent-go added" || rc=1
  assert_contains "$TI_OUT" "project: in jpmoya/41 (CD release hardening); agent-go added" "summary line" || rc=1
  : > "$TI_D/gh.log"; ti_issue OPEN "agent-go,bug"
  ti_fin "$OPS_TI" 77 --project jpmoya/41
  assert_eq "$TI_RC" "0" "second run exits 0" || rc=1
  assert_not_contains "$(ti_writes)" "issue edit" "second run relabels nothing (GitHub's item-add returns the existing item, so the project step is safe to repeat)" || rc=1
  assert_not_contains "$(grep -c '^issue view .*projectItems' "$TI_D/gh.log" || true)" "1" "projectItems is never requested (needs read:project, carries titles only)" || rc=1
  assert_contains "$TI_OUT" "agent-go already there" "says so for the label" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_go_false_goal_and_none_still_get_agent_go() {
  ti_setup
  local rc=0
  ti_fin "$SALES_TI" 12 --project jpmoya/44
  assert_eq "$TI_RC" "0" "go-false goal project accepted" || rc=1
  assert_contains "$(ti_writes)" "issue edit 12 -R $SALES_TI --add-label agent-go" "agent-go is added: JP asked for it to be worked" || rc=1
  : > "$TI_D/gh.log"
  ti_fin "$OPS_TI" 13 --none
  assert_eq "$TI_RC" "0" "--none exits 0" || rc=1
  assert_not_contains "$(ti_writes)" "project item-add" "--none touches no project" || rc=1
  assert_contains "$(ti_writes)" "issue edit 13 -R $OPS_TI --add-label agent-go" "--none still adds agent-go" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_resolves_a_renamed_repo() {
  ti_setup
  local rc=0
  ti_fin Benjis-Plants/scheduler 77 --project jpmoya/41
  assert_eq "$TI_RC" "0" "old name accepted ($TI_OUT)" || rc=1
  assert_contains "$(ti_writes)" "issue edit 77 -R $OPS_TI --add-label agent-go" "the write goes to the current repo name" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_never_skips_the_project_step_silently() {
  ti_setup
  local rc=0
  ti_fin "$OPS_TI" 77; assert_eq "$TI_RC" "3" "no --project/--none: usage error" || rc=1
  ti_fin "$OPS_TI" 77 --project jpmoya/41 --none; assert_eq "$TI_RC" "3" "both: usage error" || rc=1
  ti_fin "$OPS_TI" abc --none; assert_eq "$TI_RC" "3" "bad issue number" || rc=1
  ti_fin "$OPS_TI" 77 --project jpmoya/x; assert_eq "$TI_RC" "3" "bad project number" || rc=1
  assert_eq "$(ti_writes)" "" "nothing written on any usage error" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_refuses_a_project_that_is_not_a_registered_goals() {
  ti_setup
  local rc=0 n
  for n in 99 40 37 50; do
    ti_fin "$OPS_TI" 77 --project jpmoya/$n
    assert_eq "$TI_RC" "2" "project $n (unregistered / feedback mirror / stopped) is refused" || rc=1
  done
  ti_fin "$SALES_TI" 77 --project jpmoya/41; assert_eq "$TI_RC" "2" "a goal that does not cover the repo is refused" || rc=1
  assert_contains "$TI_OUT" "jpmoya/44" "the refusal lists the real choices" || rc=1
  assert_eq "$(ti_writes)" "" "no write after a refusal" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_no_go_needs_a_reason_and_skips_the_label() {
  ti_setup
  local rc=0
  ti_fin "$OPS_TI" 77 --none --no-go "x"; assert_eq "$TI_RC" "2" "a reasonless --no-go is refused" || rc=1
  assert_eq "$(ti_writes)" "" "nothing written" || rc=1
  ti_fin "$OPS_TI" 77 --project jpmoya/41 --no-go "fix already shipped by a bypass pipeline hotfix"
  assert_eq "$TI_RC" "0" "--no-go with a reason" || rc=1
  assert_contains "$(ti_writes)" "project item-add 41" "the project step still happens" || rc=1
  assert_not_contains "$(ti_writes)" "add-label" "no agent-go" || rc=1
  assert_contains "$(cat "$TI_D/intake.log")" "go=no reason=fix already shipped" "decision logged with the reason" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_exemptions_and_edge_states() {
  ti_setup
  local rc=0
  ti_fin jpmoya/claude-agents 5 --none
  assert_eq "$TI_RC" "0" "direct-route repo exits 0" || rc=1
  assert_contains "$TI_OUT" "direct-route" "says why nothing was done" || rc=1
  assert_eq "$(ti_writes)" "" "no project, no agent-go in the direct-route repo" || rc=1
  assert_eq "$(grep -c '^issue view' "$TI_D/gh.log" 2>/dev/null || true)" "" "not even a read (no gh call at all)" || rc=1
  ti_fin Benjis-Plants/Business-Intelligence 5 --none
  assert_eq "$TI_RC" "0" "Business-Intelligence exits 0" || rc=1
  assert_not_contains "$(ti_writes)" "add-label" "Business-Intelligence never gets an automatic agent-go" || rc=1
  assert_contains "$TI_OUT" "only JP adds it" "says why" || rc=1
  ti_issue CLOSED ""; : > "$TI_D/gh.log"
  ti_fin "$OPS_TI" 77 --none; assert_not_contains "$(ti_writes)" "add-label" "a closed issue gets no agent-go" || rc=1
  ti_issue OPEN "agent-in-progress"; : > "$TI_D/gh.log"
  ti_fin "$OPS_TI" 77 --none; assert_eq "$(ti_writes)" "" "an issue already running is left alone" || rc=1
  ti_issue OPEN "infra"; : > "$TI_D/gh.log"
  ti_fin "$OPS_TI" 77 --none; assert_contains "$TI_OUT" "every prod step still waits for JP's go" "infra: agent-go is launch permission only" || rc=1
  ti_teardown; return $rc
}

test_ti_finish_reports_a_failed_project_add_and_adds_no_label() {
  ti_setup
  local rc=0
  : > "$TI_D/fail-project"
  ti_fin "$OPS_TI" 77 --project jpmoya/41
  assert_eq "$TI_RC" "4" "a failed project add exits 4" || rc=1
  assert_contains "$TI_OUT" "project scope" "tells how to fix the token" || rc=1
  assert_not_contains "$(ti_writes)" "add-label" "no label after a failed project step (re-run finishes the job)" || rc=1
  rm -f "$TI_D/fail-project"; : > "$TI_D/fail-label"
  ti_fin "$OPS_TI" 77 --none; assert_eq "$TI_RC" "4" "a failed label add exits 4" || rc=1
  ti_teardown; return $rc
}

# ------------------------------------------------------------------ wiring + docs ------------------------------------
test_ti_wiring_and_skill_doc() {
  local rc=0 s="$ROOT_TI/settings.json" doc
  assert_eq "$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | map(select(endswith("ticket-intake-reminder.sh"))) | length' "$s")" "1" "UserPromptSubmit wires the reminder" || rc=1
  assert_eq "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | map(select(endswith("ticket-intake-guard.sh"))) | length' "$s")" "1" "PreToolUse Bash wires the guard" || rc=1
  assert_eq "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | map(select(endswith("dedupe-ticket-guard.sh"))) | length' "$s")" "1" "the dedupe guard stays wired" || rc=1
  if ! { [ -x "$REM_TI" ] && [ -x "$GUARD_TI" ] && [ -x "$HELPER_TI" ]; }; then fail "hooks and helper must be executable"; rc=1; fi
  assert_file_exists "$SKILL_TI" || return 1
  doc=$(cat "$SKILL_TI")
  assert_contains "$doc" "name: ticket-intake" "frontmatter name" || rc=1
  assert_contains "$doc" "find-duplicates.sh" "step: duplicate check first" || rc=1
  assert_contains "$doc" "product-manager" "files via the product-manager route" || rc=1
  assert_contains "$doc" "Reported by: JP (directly)" "brief carries the direct-report line" || rc=1
  assert_contains "$doc" "Intake: project=" "brief carries the marker the guard checks" || rc=1
  assert_contains "$doc" "gh project item-add" "names the project step" || rc=1
  assert_contains "$doc" "agent-go" "names the label step" || rc=1
  assert_contains "$doc" "jpmoya/claude-agents" "the direct-route exemption" || rc=1
  assert_contains "$doc" "go-false" "go-false goals still get agent-go" || rc=1
  assert_contains "$doc" "launch permission" "agent-go does not bypass JP-only gates" || rc=1
  assert_contains "$doc" "mockup approvals" "JP-only gates are listed" || rc=1
  assert_contains "$doc" "feedback goal" "feedback goals are not project-based" || rc=1
  assert_contains "$doc" "Business-Intelligence" "BI exception" || rc=1
  assert_contains "$doc" "exactly one" "one question only" || rc=1
  assert_contains "$doc" "AskUserQuestion" "the question tool and its first-attempt block" || rc=1
  return $rc
}

run_test test_ti_reminder_fires_on_every_ticket_request_phrasing
run_test test_ti_reminder_stays_quiet_on_non_requests
run_test test_ti_reminder_reads_all_three_field_names_and_skips_pipeline_agents
run_test test_ti_reminder_output_is_hook_json_with_the_hard_instruction
run_test test_ti_pattern_list_lives_in_one_file
run_test test_ti_guard_refuses_a_bare_create_on_application_repos
run_test test_ti_guard_accepts_the_intake_marker_in_every_place_it_can_live
run_test test_ti_guard_go_no_needs_a_reason
run_test test_ti_guard_exemptions
run_test test_ti_guard_ignores_everything_that_is_not_a_create
run_test test_ti_guard_enforced_set_follows_config_local
run_test test_ti_guard_and_dedupe_guard_are_independent
run_test test_ti_goals_lists_only_open_project_goals_that_fit_the_repo
run_test test_ti_finish_adds_to_the_project_and_agent_go_then_is_idempotent
run_test test_ti_finish_go_false_goal_and_none_still_get_agent_go
run_test test_ti_finish_resolves_a_renamed_repo
run_test test_ti_finish_never_skips_the_project_step_silently
run_test test_ti_finish_refuses_a_project_that_is_not_a_registered_goals
run_test test_ti_finish_no_go_needs_a_reason_and_skips_the_label
run_test test_ti_finish_exemptions_and_edge_states
run_test test_ti_finish_reports_a_failed_project_add_and_adds_no_label
run_test test_ti_wiring_and_skill_doc
