# #472 — standing staff-feedback goal `owner/repo:feedback`: a delivery lead bound to the repo's user-feedback tickets.
# #517 — its scope is every user-feedback ticket that no other LIVE goal covers (live = registry state queued, active,
# held or waiting_jp, the set deliver.sh's check_overlap uses), whatever its milestone: the product-manager gives every
# ticket a milestone, so the old "in no milestone" rule matched nothing. Reuses the dg_* sandbox of test-goal-deliver.sh
# (sourced earlier, alphabetical).
# Hand arithmetic: project-a gets feedback tickets 301 (open, no milestone), 302 (closed, no milestone),
# 303 (open, milestone 12), 304 (open, no milestone, no user-feedback label -> never in scope).
# With no other live goal the scope is {301, 302, 303}; a live goal on milestone 12 takes 303 out of it.

DGF_SPEC="example-owner/project-a:feedback"
DGF_ID="example-owner_project-a-fb-feedback"

dgf_label() {  # dgf_label <n> <label>
  local f="$DG_ST/issues/example-owner_project-a/$1.json"
  jq -c --arg l "$2" '.labels += [{name:$l}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

dgf_setup() {
  dg_setup
  local a=example-owner_project-a
  dg_issue $a 301 open; dg_issue $a 302 closed; dg_issue $a 303 open 12; dg_issue $a 304 open
  dgf_label 301 user-feedback; dgf_label 302 user-feedback; dgf_label 303 user-feedback
}

test_dgf_parse_and_id() {
  dgf_setup
  local rc=0
  dg_lib "goal_parse $DGF_SPEC; goal_id $DGF_SPEC"
  assert_eq "$DG_RC" "0" "parse exits 0 ($DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "$(printf 'example-owner/project-a\tfb\tfeedback')" "kind fb" || rc=1
  assert_contains "$DG_OUT" "$DGF_ID" "goal id" || rc=1
  dg_teardown; return $rc
}

test_dgf_scope_is_every_feedback_ticket_when_no_other_goal_is_live() {
  dgf_setup
  local rc=0
  dg_lib "_goal_scope_rows $DGF_SPEC"
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | sort)" "$(printf 'example-owner/project-a#301\topen\nexample-owner/project-a#302\tclosed\nexample-owner/project-a#303\topen')" \
    "scope rows: 303 is in milestone 12 and still in scope (#517)" || rc=1
  dg_teardown; return $rc
}

test_dgf_register_grants_no_agent_go_and_launches_lead() {
  dgf_setup
  local rc=0 f blk
  dg_run "$DGF_SPEC" --now
  assert_eq "$DG_RC" "0" "register exits 0 ($DG_ERR)" || rc=1
  f=$(dg_reg_file_for "$DGF_ID"); assert_ne "$f" "" "registry block carries the id" || rc=1
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r '.spec')" "$DGF_SPEC" "spec recorded" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r '.go // false')" "false" "no go recorded" || rc=1
  assert_eq "$(grep -c 'agent-go' "$DG_BIN/writes.log")" "0" "no agent-go label write" || rc=1
  assert_contains "$DG_ERR" "no go granted" "operator is told no go was granted" || rc=1
  dg_wait_claude 1 || { fail 'lead was never launched'; rc=1; }
  dg_teardown; return $rc
}

test_dgf_register_refused_when_no_feedback_ticket_in_scope() {
  dg_setup
  local rc=0
  dg_run "$DGF_SPEC"
  assert_ne "$DG_RC" "0" "empty scope refused" || rc=1
  assert_contains "$DG_ERR" "empty scope" "reason" || rc=1
  dg_teardown; return $rc
}

test_dgf_brief_states_the_job_and_the_limits() {
  dgf_setup
  local rc=0 out
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  DG_GOAL_ID=$DG_ID_MS; dg_goal 502 "$DG_SPEC_MS" host-a active   # milestone 12's own goal covers 303
  dg_lib "goal_brief $DGF_ID"
  out=$DG_OUT
  assert_eq "$DG_RC" "0" "brief exits 0 ($DG_ERR)" || rc=1
  assert_contains "$out" "TECHNICAL blocks" "job" || rc=1
  assert_contains "$out" "Never add agent-go" "limit" || rc=1
  assert_contains "$out" "project-a#301" "open feedback ticket in scope" || rc=1
  assert_not_contains "$out" "project-a#303" "feedback ticket covered by the live milestone-12 goal out of scope" || rc=1
  assert_contains "$out" "no other live goal covers" "brief states the #517 scope rule" || rc=1
  assert_not_contains "$out" "project-a#304" "unlabelled ticket out of scope" || rc=1
  dg_teardown; return $rc
}

test_dgf_overlap_with_milestone_goal_on_other_tickets_accepted() {
  dgf_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 501 "$DG_SPEC_MS" host-a active
  dg_run "$DGF_SPEC"
  assert_eq "$DG_RC" "0" "feedback goal beside a milestone goal (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

test_dgf_delivered_when_every_feedback_ticket_is_closed() {
  dgf_setup
  local rc=0
  dg_set_state example-owner_project-a 301 closed; dg_set_state example-owner_project-a 303 closed
  dg_lib "goal_eval $DGF_ID $DGF_SPEC; echo \$GE_TOTAL \$GE_DELIVERED"
  assert_eq "$DG_OUT" "3 3" "all scope tickets closed = goal complete (301, 302, 303)" || rc=1
  dg_teardown; return $rc
}

test_dgf_docs_name_the_goal() {
  local root; root=$(cd "$DG_SKILL/../.." && pwd)
  assert_contains "$(cat "$root/agents/delivery-lead.md")" "owner/repo:feedback" "delivery-lead.md" || return 1
  assert_contains "$(cat "$DG_SKILL/SKILL.md")" "owner/repo:feedback" "SKILL.md" || return 1
  assert_contains "$(cat "$root/README.md")" "owner/repo:feedback" "README.md" || return 1
}

# ---------------------------------------------------------------- #517: scope = not covered by another live goal --
# Extra fixture: 305 is an open user-feedback ticket in milestone 13 (whose goal id is example-owner_project-a-ms-13).
# Expected per state of the milestone-13 goal, from the ticket: queued / active / held / waiting_jp cover 305 (out of the
# feedback scope); delivered / stopped do not (305 back in). 301 / 302 / 303 stay in scope throughout (no goal covers them).

DGF_SPEC_MS13="example-owner/project-a:milestone:13"
DGF_ID_MS13="example-owner_project-a-ms-13"

dgf_setup_517() {
  dgf_setup
  dg_issue example-owner_project-a 305 open 13; dgf_label 305 user-feedback
}

# dgf_goal_in_state <registry n> <spec> <id> <queued|active|held|waiting_jp|delivered|stopped>
dgf_goal_in_state() {
  local st=$4 f
  DG_GOAL_ID=$3
  case "$st" in
    queued) dg_goal "$1" "$2" "" active
            f="$DG_ST/issues/$DG_REG/$1.json"
            jq -c '.labels += [{name:"goal-queued"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
    waiting_jp) dg_goal "$1" "$2" host-a waiting ;;
    *) dg_goal "$1" "$2" host-a "$st" ;;
  esac
}

# dgf_label_goal <registry n> <label> <repos csv> — a live (active) cross-repo label goal, v2 block as register writes it
dgf_label_goal() {
  local id block
  id=$(printf 'label-%s' "$2" | sed 's/[^A-Za-z0-9._-]/_/g')
  block=$(jq -nc --arg id "$id" --arg l "$2" --arg c "$DG_NOW" --argjson r "$(printf '%s' "$3" | jq -Rc 'split(",")')" \
    '{v:2,id:$id,title:$l,label:$l,repos:$r,order:0,go:false,spec:("label:" + $l),host:"host-a",created:$c,instructions:""}')
  jq -nc --argjson n "$1" --arg body "$(printf 'Goal: label:%s\n\n```json\n%s\n```\n' "$2" "$block")" --arg now "$DG_NOW" \
    '{number:$n, title:"Goal", body:$body, state:"open", labels:[{name:"delivery-goal"}], milestone:null,
      closed_at:null, created_at:$now, updated_at:$now}' > "$DG_ST/issues/$DG_REG/$1.json"
}

# dgf_canon <slug> <canonical> — seed repo_canon's 1-hour cache (the fake gh has no `gh repo view`)
dgf_canon() { mkdir -p "$DG_PIPE/repo-canon"; printf '%s' "$2" > "$DG_PIPE/repo-canon/${1//\//__}"; }

dgf_scope_numbers() {  # the issue numbers of the feedback scope, sorted, space-separated (DG_OUT/DG_RC from dg_lib)
  dg_lib "_goal_scope_rows $DGF_SPEC"
  DGF_NUMS=$(printf '%s\n' "$DG_OUT" | cut -f1 | sed -n 's/.*#//p' | sort -n | tr '\n' ' ' | sed 's/ $//')
}

# AC1: a milestoned feedback ticket no live goal covers is IN scope; one an active goal covers is OUT
test_dgf517_milestoned_ticket_in_scope_unless_an_active_goal_covers_it() {
  dgf_setup_517
  local rc=0
  dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" active
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303" "303 (milestone 12, no live goal) in; 305 (active milestone-13 goal) out" || rc=1
  dg_lib "goal_eval $DGF_ID $DGF_SPEC; echo \$GE_TOTAL \$GE_DELIVERED"
  assert_eq "$DG_OUT" "3 1" "goal_eval counts 301, 302 (closed), 303" || rc=1
  dg_teardown; return $rc
}

# AC2: queued, held and waiting_jp goals cover their tickets too (check_overlap's whole live set, not just active)
test_dgf517_queued_held_and_waiting_goals_also_cover() {
  local rc=0 st
  for st in queued held waiting_jp; do
    dgf_setup_517
    dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" "$st"
    dgf_scope_numbers
    assert_eq "$DG_RC" "0" "$st: scope read exits 0 ($DG_ERR)" || rc=1
    assert_eq "$DGF_NUMS" "301 302 303" "$st milestone-13 goal still covers 305" || rc=1
    dg_teardown
  done
  return $rc
}

# AC3: a delivered goal no longer covers anything: 305 is back in the feedback scope. So does a goal stopped before #527
# (its block records no `stopped_open` hold); a stop made by `deliver.sh stop` since #527 holds — see the #527 tests below.
test_dgf517_delivered_and_stopped_goals_do_not_cover() {
  local rc=0 st
  for st in delivered stopped; do
    dgf_setup_517
    dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" "$st"
    dgf_scope_numbers
    assert_eq "$DG_RC" "0" "$st: scope read exits 0 ($DG_ERR)" || rc=1
    assert_eq "$DGF_NUMS" "301 302 303 305" "$st milestone-13 goal (no hold recorded) covers nothing" || rc=1
    dg_teardown
  done
  return $rc
}

# A goal stored under the repo's pre-rename slug still covers its tickets (Benjis-Plants/scheduler = benjis-ops-tool):
# the old slug's REST path reaches the same issues (GitHub redirects; here a symlinked state dir) and repo_canon maps it.
test_dgf517_goal_under_an_old_repo_slug_still_covers() {
  dgf_setup_517
  local rc=0
  ln -s example-owner_project-a "$DG_ST/issues/example-owner_old-project-a"
  dgf_canon example-owner/old-project-a example-owner/project-a; dgf_canon example-owner/project-a example-owner/project-a
  dgf_goal_in_state 502 "example-owner/old-project-a:milestone:13" "example-owner_old-project-a-ms-13" active
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303" "305 covered by the old-slug milestone-13 goal" || rc=1
  dg_teardown; return $rc
}

# A cross-repo label goal covers only its tickets in THIS repo: project-b#303 carrying the label does not take
# project-a#303 out of scope; project-a#305 carrying it does.
test_dgf517_label_goal_covers_only_its_tickets_in_this_repo() {
  dgf_setup_517
  local rc=0
  dg_issue example-owner_project-b 303 open
  jq -c '.labels += [{name:"goalx"}]' "$DG_ST/issues/example-owner_project-b/303.json" > "$DG_HOME/t" && mv "$DG_HOME/t" "$DG_ST/issues/example-owner_project-b/303.json"
  dgf_label 305 goalx
  dgf_canon example-owner/project-a example-owner/project-a; dgf_canon example-owner/project-b example-owner/project-b
  dgf_label_goal 502 goalx "example-owner/project-b,example-owner/project-a"
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303" "label goal covers project-a#305 only" || rc=1
  dg_teardown; return $rc
}

# Observability + fail closed: an unreadable live registry entry, or a repo name that cannot be resolved, makes the
# feedback scope unreadable (exit 1, no rows, goal_eval fails) and is logged via slog with release, host and route.
test_dgf517_unreadable_registry_fails_closed_and_logs() {
  dgf_setup_517
  local rc=0 log
  jq -nc --arg now "$DG_NOW" '{number:503, title:"Goal: broken", body:"no block here", state:"open",
    labels:[{name:"delivery-goal"}], milestone:null, closed_at:null, created_at:$now, updated_at:$now}' > "$DG_ST/issues/$DG_REG/503.json"
  dg_lib 'slog() { printf "%s\n" "$*" >> "$PIPE/test-slog"; }; _goal_scope_rows '"$DGF_SPEC"
  assert_ne "$DG_RC" "0" "unreadable registry entry: scope read fails" || rc=1
  assert_eq "$DG_OUT" "" "no rows: never an empty-but-successful scope" || rc=1
  log=$(cat "$DG_PIPE/test-slog" 2>/dev/null)
  assert_contains "$log" "route=goal-fb-scope" "slog route" || rc=1
  assert_contains "$log" "host=host-a" "slog host" || rc=1
  assert_contains "$log" "release=" "slog release" || rc=1
  assert_contains "$log" "#503" "slog names the registry issue" || rc=1
  dg_lib "goal_eval $DGF_ID $DGF_SPEC"
  assert_ne "$DG_RC" "0" "goal_eval fails rather than reading an empty scope" || rc=1
  dg_teardown

  dgf_setup_517
  dgf_label_goal 502 goalx "example-owner/project-b"   # no repo-canon cache, fake gh has no `gh repo view`
  rm -f "$DG_PIPE/test-slog" "$DG_PIPE/repo-canon/example-owner__project-b"   # dg_setup seeds it since #527
  dg_lib 'slog() { printf "%s\n" "$*" >> "$PIPE/test-slog"; }; _goal_scope_rows '"$DGF_SPEC"
  assert_ne "$DG_RC" "0" "unresolvable repo name: scope read fails" || rc=1
  assert_contains "$(cat "$DG_PIPE/test-slog" 2>/dev/null)" "route=goal-fb-scope" "slog route (repo name)" || rc=1
  dg_teardown; return $rc
}

# A live feedback goal yields: registering a milestone goal whose milestone holds a feedback ticket is accepted
# (before #517's yield rule, check_overlap read the feedback goal's scope, found 305 in it and refused).
test_dgf517_live_feedback_goal_does_not_block_registering_a_milestone_goal() {
  dgf_setup_517
  local rc=0
  dg_run "$DGF_SPEC"
  assert_eq "$DG_RC" "0" "feedback goal registers ($DG_ERR)" || rc=1
  dg_run "$DGF_SPEC_MS13"
  assert_eq "$DG_RC" "0" "milestone-13 goal (holds feedback ticket 305) registers beside the live feedback goal ($DG_ERR)" || rc=1
  dgf_scope_numbers
  assert_eq "$DGF_NUMS" "301 302 303" "and 305 has left the feedback scope" || rc=1
  dg_run "$DGF_SPEC"
  assert_ne "$DG_RC" "0" "the same feedback goal twice is still refused" || rc=1
  assert_contains "$DG_ERR" "same goal" "reason" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- #527: review fixes on #517 --------------------
# dgf_reg_block_set <registry n> <jq filter> — rewrite the fenced json block of a registry issue in place
dgf_reg_block_set() {
  local f="$DG_ST/issues/$DG_REG/$1.json" blk
  blk=$(dg_block "$f" | jq -c "$2")
  jq -c --arg b "$(printf 'Goal: x\n\n```json\n%s\n```\n' "$blk")" '.body = $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# HIGH (regression): a live milestone-13 goal (covers 305) whose block has a malformed field — `repos` a string, so jq
# cannot iterate it — must make the feedback scope UNREADABLE, never every feedback ticket. Before the fix the jq error
# was swallowed by the here-string: zero registry rows, nothing covered, rc 0 and 305 in the feedback scope (double cover).
test_dgf527_malformed_live_registry_entry_fails_closed() {
  dgf_setup_517
  local rc=0 log
  dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" active
  dgf_reg_block_set 502 '.repos = "example-owner/project-a"'
  dg_lib 'slog() { printf "%s\n" "$*" >> "$PIPE/test-slog"; }; _goal_scope_rows '"$DGF_SPEC"
  assert_ne "$DG_RC" "0" "malformed live entry: the feedback scope read fails" || rc=1
  assert_not_contains "$DG_OUT" "#305" "305 (covered by the malformed live goal) is never handed to the feedback goal" || rc=1
  assert_eq "$DG_OUT" "" "no rows at all" || rc=1
  log=$(cat "$DG_PIPE/test-slog" 2>/dev/null)
  assert_contains "$log" "does not parse" "logged: the registry entry does not parse" || rc=1
  assert_contains "$log" "route=goal-fb-scope" "logged on the feedback-scope route" || rc=1
  dg_lib "goal_eval $DGF_ID $DGF_SPEC"
  assert_ne "$DG_RC" "0" "goal_eval fails" || rc=1
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  dg_lib "goal_brief $DGF_ID"
  assert_ne "$DG_RC" "0" "no brief, so no lead cycle, while the registry is malformed" || rc=1
  dg_teardown; return $rc
}

# A malformed CLOSED (delivered) entry is not read field by field: it cannot wedge the feedback goal.
test_dgf527_malformed_delivered_entry_does_not_wedge() {
  dgf_setup_517
  local rc=0
  dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" delivered
  dgf_reg_block_set 502 '.repos = "example-owner/project-a"'
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303 305" "delivered goal covers nothing" || rc=1
  dg_teardown; return $rc
}

# MEDIUM (b): `deliver.sh stop` no longer hands the goal's open tickets back. 305 stays out of the feedback scope after
# the stop, also once the stop is older than GOAL_RECENT_DAYS (7), until `deliver.sh release`; then it is back in.
test_dgf527_stopped_goal_holds_its_tickets_until_release() {
  dgf_setup_517
  local rc=0 f blk
  dg_run "$DGF_SPEC_MS13"
  assert_eq "$DG_RC" "0" "milestone-13 goal registers ($DG_ERR)" || rc=1
  dg_run stop "$DGF_ID_MS13"
  assert_eq "$DG_RC" "0" "stop exits 0 ($DG_ERR)" || rc=1
  assert_contains "$DG_ERR" "deliver.sh release $DGF_ID_MS13" "the operator is told how to hand the tickets back" || rc=1
  f=$(dg_reg_file_for "$DGF_ID_MS13"); blk=$(dg_block "$f")
  # milestone 13 holds 201 (open, from dg_seed) and 305 (open, user-feedback): the hold is every open ticket at the stop
  assert_eq "$(printf '%s' "$blk" | jq -c '.stopped_open | sort')" '["example-owner/project-a#201","example-owner/project-a#305"]' \
    "hold = the open tickets of milestone 13 at the stop" || rc=1
  assert_eq "$(jq -r .state "$f")" "closed" "registry issue closed" || rc=1
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "scope read exits 0 ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303" "305 held out of the feedback scope by the stopped goal" || rc=1
  jq -c --arg o "$DG_OLD" '.closed_at = $o | .updated_at = $o' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  dgf_scope_numbers
  assert_eq "$DGF_NUMS" "301 302 303" "still held 10 days after the stop (past GOAL_RECENT_DAYS)" || rc=1
  dg_run release "$DGF_ID_MS13"
  assert_eq "$DG_RC" "0" "release exits 0 ($DG_ERR)" || rc=1
  assert_eq "$(dg_block "$f" | jq -r '.stopped_open // "none"')" "none" "hold cleared from the block" || rc=1
  assert_ne "$(dg_block "$f" | jq -r '.released_at // ""')" "" "release recorded" || rc=1
  dgf_scope_numbers
  assert_eq "$DGF_NUMS" "301 302 303 305" "after the release 305 is back in the feedback scope" || rc=1
  dg_teardown; return $rc
}

# A stop that could not list the goal's tickets holds the whole repo: the feedback scope fails closed (logged) until release.
test_dgf527_unreadable_hold_fails_closed_until_release() {
  dgf_setup_517
  local rc=0
  dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" stopped
  dgf_reg_block_set 502 '.stopped_open = "unreadable"'
  dg_lib 'slog() { printf "%s\n" "$*" >> "$PIPE/test-slog"; }; _goal_scope_rows '"$DGF_SPEC"
  assert_ne "$DG_RC" "0" "unlisted hold on this repo: the feedback scope read fails" || rc=1
  assert_contains "$(cat "$DG_PIPE/test-slog" 2>/dev/null)" "deliver.sh release $DGF_ID_MS13" "logged with the way out" || rc=1
  dg_run release "$DGF_ID_MS13"
  assert_eq "$DG_RC" "0" "release exits 0 ($DG_ERR)" || rc=1
  dgf_scope_numbers
  assert_eq "$DG_RC" "0" "readable again after the release ($DG_ERR)" || rc=1
  assert_eq "$DGF_NUMS" "301 302 303 305" "305 back in" || rc=1
  dg_teardown; return $rc
}

# dgf_fb_lead_running <launch-scope refs...> — a live feedback lead cycle on this host: cache, pid of a live process tree,
# and the launch scope goal_launch records (#527)
dgf_fb_lead_running() {
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  jq -nc --arg s "$DGF_SPEC" '{v:1,id:"'"$DGF_ID"'",spec:$s,host:"host-a",issue:501}' > "$DG_PIPE/goal-$DGF_ID.json"
  dg_live_tree; dg_pidfile "$DGF_ID" "$DG_P"
  printf '%s\n' "$@" > "$DG_PIPE/goal-$DGF_ID.launch-scope"
}

# MEDIUM (a): registering a milestone goal over a ticket a running feedback cycle was launched with ends that cycle
# at once (same host), with a .yielded marker, instead of letting both leads work 305 until the next scope read.
test_dgf527_register_over_a_running_feedback_cycle_ends_it_now() {
  dgf_setup_517
  local rc=0
  dgf_fb_lead_running example-owner/project-a#301 example-owner/project-a#305
  dg_run "$DGF_SPEC_MS13"
  assert_eq "$DG_RC" "0" "milestone-13 goal registers ($DG_ERR)" || rc=1
  dg_wait_dead "$DG_P" || { fail "the feedback cycle launched with 305 is still running"; rc=1; }
  assert_eq "$(cat "$DG_PIPE/goal-$DGF_ID.yielded" 2>/dev/null)" "example-owner/project-a#305" "yield marker names the ticket taken over" || rc=1
  dg_teardown; return $rc
}

# ...and a feedback cycle the new goal does not touch keeps running.
test_dgf527_register_elsewhere_leaves_the_feedback_cycle_alone() {
  dgf_setup_517
  local rc=0
  dgf_fb_lead_running example-owner/project-a#301 example-owner/project-a#303
  dg_run "$DGF_SPEC_MS13"
  assert_eq "$DG_RC" "0" "milestone-13 goal registers ($DG_ERR)" || rc=1
  dg_alive "$DG_P" || { fail "a feedback cycle with no ticket of milestone 13 was killed"; rc=1; }
  assert_file_absent "$DG_PIPE/goal-$DGF_ID.yielded" "no yield marker" || rc=1
  dg_teardown; return $rc
}

# The supervisor side (any host): at sync the alive branch ends the cycle; the next tick relaunches at once and counts
# neither a restart nor a launch failure (#514's counters stay untouched).
test_dgf527_tick_yields_then_relaunches_without_counting_a_crash() {
  dgf_setup_517
  local rc=0
  dgf_goal_in_state 502 "$DGF_SPEC_MS13" "$DGF_ID_MS13" active
  dgf_fb_lead_running example-owner/project-a#305
  echo 0 > "$DG_PIPE/goal-$DGF_ID.restarts"; echo 0 > "$DG_PIPE/goal-$DGF_ID.launchfails"
  date -u +%FT%TZ > "$DG_PIPE/goal-$DGF_ID.launched-at"
  dg_lib "slog() { :; }; GOAL_SYNC_DUE=1; GOAL_CAN_LAUNCH=1; goal_tick_one $DGF_ID"
  assert_eq "$DG_RC" "0" "tick exits 0 ($DG_ERR)" || rc=1
  dg_wait_dead "$DG_P" || { fail "the yielding cycle is still running"; rc=1; }
  assert_file_exists "$DG_PIPE/goal-$DGF_ID.yielded" "yield marker" || rc=1
  dg_lib "slog() { :; }; GOAL_SYNC_DUE=1; GOAL_CAN_LAUNCH=1; goal_tick_one $DGF_ID"
  assert_eq "$DG_RC" "0" "relaunch tick exits 0 ($DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "the feedback lead was not relaunched at once"; rc=1; }
  assert_eq "$(cat "$DG_PIPE/goal-$DGF_ID.restarts")" "0" "no restart counted" || rc=1
  assert_eq "$(cat "$DG_PIPE/goal-$DGF_ID.launchfails")" "0" "no launch failure counted" || rc=1
  assert_file_absent "$DG_PIPE/goal-$DGF_ID.yielded" "marker consumed by the relaunch" || rc=1
  assert_eq "$(sort "$DG_PIPE/goal-$DGF_ID.launch-scope" 2>/dev/null | tr '\n' ' ')" "example-owner/project-a#301 example-owner/project-a#303 " \
    "new launch scope = the open feedback tickets left (301, 303), 305 out" || rc=1
  dg_teardown; return $rc
}

# MEDIUM (check_overlap canonicalization): a live milestone-13 goal stored under the old slug overlaps the same
# milestone, and a single ticket of it, registered under the new slug.
test_dgf527_overlap_check_sees_through_a_repo_rename() {
  local rc=0 spec
  for spec in "$DGF_SPEC_MS13" "example-owner/project-a#305"; do
    dgf_setup_517
    ln -s example-owner_project-a "$DG_ST/issues/example-owner_old-project-a"
    cp "$DG_ST/milestones/example-owner_project-a.json" "$DG_ST/milestones/example-owner_old-project-a.json"
    dgf_canon example-owner/old-project-a example-owner/project-a
    dgf_goal_in_state 502 "example-owner/old-project-a:milestone:13" "example-owner_old-project-a-ms-13" active
    dg_run "$spec"
    assert_ne "$DG_RC" "0" "$spec refused beside the old-slug milestone-13 goal" || rc=1
    assert_contains "$DG_ERR" "overlaps live goal example-owner_old-project-a-ms-13" "$spec: names the live goal" || rc=1
    dg_teardown
  done
  return $rc
}

# ...and a repo name that cannot be resolved refuses rather than reading as "another repo".
test_dgf527_overlap_check_refuses_an_unresolvable_repo() {
  dgf_setup_517
  local rc=0
  dgf_goal_in_state 502 "example-owner/project-c:milestone:13" "example-owner_project-c-ms-13" active   # project-c: no canon cache
  dg_run "$DGF_SPEC_MS13"
  assert_ne "$DG_RC" "0" "refused" || rc=1
  assert_contains "$DG_ERR" "refusing to go on blind" "reason" || rc=1
  dg_teardown; return $rc
}

# The project sync only adds items, so a ticket another goal took over stays on the feedback goal's board: the brief must
# make the live Scope list, not the project, the lead's ticket list.
test_dgf527_brief_scope_list_beats_the_project_board() {
  dgf_setup_517
  local rc=0
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  dgf_reg_block_set 501 '.project = {owner:"example-owner", number:7, url:"https://github.com/users/example-owner/projects/7"}'
  dg_lib "goal_brief $DGF_ID"
  assert_eq "$DG_RC" "0" "brief exits 0 ($DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "not the project, is your ticket list" "feedback brief: the Scope list is authoritative" || rc=1
  dg_teardown; return $rc
}

for t in test_dgf527_brief_scope_list_beats_the_project_board \
         test_dgf527_malformed_live_registry_entry_fails_closed test_dgf527_malformed_delivered_entry_does_not_wedge \
         test_dgf527_stopped_goal_holds_its_tickets_until_release test_dgf527_unreadable_hold_fails_closed_until_release \
         test_dgf527_register_over_a_running_feedback_cycle_ends_it_now test_dgf527_register_elsewhere_leaves_the_feedback_cycle_alone \
         test_dgf527_tick_yields_then_relaunches_without_counting_a_crash test_dgf527_overlap_check_sees_through_a_repo_rename \
         test_dgf527_overlap_check_refuses_an_unresolvable_repo; do
  run_test "$t"
done

for t in test_dgf517_milestoned_ticket_in_scope_unless_an_active_goal_covers_it test_dgf517_queued_held_and_waiting_goals_also_cover \
         test_dgf517_delivered_and_stopped_goals_do_not_cover test_dgf517_goal_under_an_old_repo_slug_still_covers \
         test_dgf517_label_goal_covers_only_its_tickets_in_this_repo test_dgf517_unreadable_registry_fails_closed_and_logs \
         test_dgf517_live_feedback_goal_does_not_block_registering_a_milestone_goal; do
  run_test "$t"
done

for t in test_dgf_parse_and_id test_dgf_scope_is_every_feedback_ticket_when_no_other_goal_is_live \
         test_dgf_register_grants_no_agent_go_and_launches_lead test_dgf_register_refused_when_no_feedback_ticket_in_scope \
         test_dgf_brief_states_the_job_and_the_limits test_dgf_overlap_with_milestone_goal_on_other_tickets_accepted \
         test_dgf_delivered_when_every_feedback_ticket_is_closed test_dgf_docs_name_the_goal; do
  run_test "$t"
done
