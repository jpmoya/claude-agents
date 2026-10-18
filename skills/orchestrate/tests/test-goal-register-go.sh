# Issue #410 — registering a milestone / #N goal is JP's go: the goal block records go:true + granted, agent-go is given to
# the open in-scope tickets (shared _goal_grant_go path), goal_sync grants later arrivals, the body-line approval is gone.
#   AC1 grg_reg_*       register writes go/granted/granted_at and labels (milestone and #N goals)
#   AC2 grg_guard_*     BI, source:sentry, msall without --approve-all, closed, no duplicate edits, stripped agent-go
#   AC3 grg_sync_*      goal_sync grants tickets added after registration (milestone and #N goals)
#   AC4 grg_appr_*      goal_milestone_approved reads block.go; no "Approved-by" in skills/orchestrate/*.sh or agents/
#   AC6 grg_waiting_*   characterisation: an agent-proposed ticket without agent-go still classes waiting_jp (green by design)
#   AC7 grg_gates_*     only agent-go / agent-proposed labels are written, no non-REST call
#   AC8 grg_log_*       every refused or failed label write -> slog `repo=<owner/repo> issue=<n> reason=<text>`
#   AC9 grg_v1_*        a v1 goal with no go field grants nothing (green by design)
#   AC10 grg_launch_*   newly registered milestone goal whose tickets are agent-proposed: no waiting-on-JP, lead launches
#   AC15 grg_capture_*  a failed label write during sync is captured as an `error` event (route/release), no secrets
# AC5 (docs) lives in test-goal-inherit-approval.sh; AC11 = existing suites stay green (not a new test).
# Log form (AC8), chosen here: slog line with the tokens `repo=<owner/repo> issue=<n> reason=<text>`. deliver.sh's slog is
# stderr (DG_ERR); inside the library the tests inject a capturing slog. Captured event (AC15) = the existing goal_err ->
# pipeline_event error row in $LOGDIR/events.jsonl (route supervisor/goal…, release non-empty).
# Reuses the dg_/glb_ sandbox (test-goal-deliver.sh and test-goal-label.sh are sourced first, alphabetical).
# World: project-a milestone 12; hand arithmetic below. Placeholder repo names only.

GRG_A=example-owner_project-a
GRG_BI=example-owner_Business-Intelligence
GRG_RA=example-owner/project-a
GRG_RBI=example-owner/Business-Intelligence
GRG_SECRET_BODY="ZZ-SECRET-TICKET-BODY-ZZ"

# grg_ticket <rk> <n> <open|closed> <labels-csv> <milestone|""> [body]
grg_ticket() {
  local rk=$1 n=$2 st=$3 lb=$4 ms=$5 body=${6:-}
  jq -nc --argjson n "$n" --arg st "$st" --arg lb "$lb" --arg ms "$ms" --arg body "$body" --arg now "$DG_NOW" '
    {number:$n, title:("ticket " + ($n|tostring)), body:$body, state:$st,
     labels:($lb | split(",") | map(select(length > 0)) | map({name:.})),
     milestone:(if $ms == "" then null else {number:($ms|tonumber), title:"m"} end),
     created_at:$now, updated_at:$now, closed_at:(if $st == "closed" then $now else null end)}' > "$DG_ST/issues/$rk/$n.json"
}

# Milestone 12 (project-a): 101 open agent-proposed, 102 open (no labels), 103 closed, 104 open source:sentry,
# 105 open already agent-go. Each open one that should be launchable carries a READY marker (dg_seed gave 101 one).
grg_world() {
  glb_setup
  rm -f "$DG_ST"/comments/*.json
  grg_ticket $GRG_A 101 open "agent-proposed" 12
  grg_ticket $GRG_A 102 open "" 12
  grg_ticket $GRG_A 103 closed "" 12
  grg_ticket $GRG_A 104 open "source:sentry,agent-proposed" 12
  grg_ticket $GRG_A 105 open "agent-go" 12 "$GRG_SECRET_BODY"
  local n
  for n in 101 102 104 105; do dg_comment $GRG_A $n $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'; done
}
grg_has() { glb_has_label "$1" "$2" "$3"; }                  # <rk> <n> <label>
grg_reg_block() { dg_block "$(dg_reg_files | head -1)"; }
grg_reg_body() { jq -r .body "$(dg_reg_files | head -1)"; }
grg_posts_for() { grep "POST repos/$1/issues/$2/labels" "$DG_BIN/writes.log" | wc -l | tr -d ' '; }          # <owner/repo> <n>
grg_cache_registered() { local f id; f=$(dg_reg_files | head -1); id=$(dg_block "$f" | jq -r .id); GRG_ID=$id; glb_cache "$(basename "$f" .json)" "$id"; }
# grg_sync — glb_sync with slog captured into $HOME/slog.txt (glb_sync already does that)
grg_slog() { cat "$DG_HOME/slog.txt" 2>/dev/null; }
grg_fail_label_post() {  # <issue n> — every label POST to that issue now fails (HTTP 500)
  mv "$DG_BIN/gh" "$DG_BIN/gh.grg"
  cat > "$DG_BIN/gh" <<'GRG_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
n=$(cat "$HERE/fail-label-n" 2>/dev/null)
case "$*" in *"-X POST"*"/issues/$n/labels"*) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;; esac
exec "$HERE/gh.grg" "$@"
GRG_EOF
  chmod +x "$DG_BIN/gh"; echo "$1" > "$DG_BIN/fail-label-n"
}

# ------------------------------------------------------------------ AC1: register records go and labels

test_grg_reg_milestone_goal_writes_go_granted_and_labels() {
  grg_world; local rc=0 blk
  dg_run "$DG_SPEC_MS" --now
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  blk=$(grg_reg_block)
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "block.go is true" || rc=1
  # 101 and 102 are open and unguarded -> both granted; 103 closed and 104 sentry (no flag) -> neither
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#101" '(.granted // []) | index($a) != null')" "true" "granted lists a#101" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#102" '(.granted // []) | index($a) != null')" "true" "granted lists a#102" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#103" '(.granted // []) | index($a) != null')" "false" "granted omits closed a#103" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#104" '(.granted // []) | index($a) != null')" "false" "granted omits sentry a#104" || rc=1
  printf '%s' "$(printf '%s' "$blk" | jq -r '.granted_at // ""')" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || { fail "block.granted_at is an ISO date, got [$(printf '%s' "$blk" | jq -r '.granted_at // ""')]"; rc=1; }
  grg_has $GRG_A 101 agent-go || { fail "a#101 gets agent-go"; rc=1; }
  grg_has $GRG_A 101 agent-proposed && { fail "a#101 loses agent-proposed"; rc=1; }
  grg_has $GRG_A 102 agent-go || { fail "a#102 gets agent-go"; rc=1; }
  glb_teardown; return $rc
}

test_grg_reg_ticket_goal_writes_go_and_labels() {
  grg_world; local rc=0 blk
  grg_ticket $GRG_A 7 open "agent-proposed" ""
  dg_run "$DG_SPEC_T7" --now
  assert_eq "$DG_RC" "0" "register #N goal exits 0 (stderr: $DG_ERR)" || rc=1
  blk=$(grg_reg_block)
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "#N goal: block.go is true" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#7" '(.granted // []) | index($a) != null')" "true" "#N goal: granted lists a#7" || rc=1
  grg_has $GRG_A 7 agent-go || { fail "#N goal: a#7 gets agent-go"; rc=1; }
  grg_has $GRG_A 7 agent-proposed && { fail "#N goal: a#7 loses agent-proposed"; rc=1; }
  glb_teardown; return $rc
}

test_grg_reg_queued_goal_also_records_go() {   # no --now: queued goal still records the go (JP's registration is the go)
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "queued register exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(grg_reg_block | jq -r .go)" "true" "queued goal: block.go is true" || rc=1
  grg_has $GRG_A 102 agent-go || { fail "queued goal: a#102 gets agent-go"; rc=1; }
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC2: guards

test_grg_guard_business_intelligence_never_labelled() {
  grg_world; local rc=0
  dg_milestone $GRG_BI 5 "bi milestone"
  mkdir -p "$DG_ST/issues/$GRG_BI"
  grg_ticket $GRG_BI 1 open "agent-proposed" 5
  dg_run "$GRG_RBI:milestone:5" --now
  grg_has $GRG_BI 1 agent-go && { fail "a Business-Intelligence ticket must never get agent-go"; rc=1; }
  grg_has $GRG_BI 1 agent-proposed || { fail "BI ticket keeps agent-proposed"; rc=1; }
  assert_contains "$DG_ERR" "repo=$GRG_RBI issue=1 reason=" "BI refusal is logged (repo, issue, reason)" || rc=1
  assert_contains "$DG_ERR" "Business-Intelligence" "BI refusal reason names Business-Intelligence" || rc=1
  glb_teardown; return $rc
}

test_grg_guard_sentry_skipped_without_flag() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_has $GRG_A 102 agent-go || { fail "positive control: a#102 labelled"; rc=1; }
  grg_has $GRG_A 104 agent-go && { fail "source:sentry a#104 must not get agent-go without --include-sentry"; rc=1; }
  assert_contains "$DG_ERR" "repo=$GRG_RA issue=104 reason=" "sentry skip is logged (repo, issue, reason)" || rc=1
  assert_contains "$DG_ERR" "source:sentry" "sentry skip reason names source:sentry" || rc=1
  glb_teardown; return $rc
}

test_grg_guard_sentry_labelled_with_include_sentry() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --include-sentry --now
  assert_eq "$DG_RC" "0" "register --include-sentry on a milestone goal exits 0 (stderr: $DG_ERR)" || rc=1
  grg_has $GRG_A 104 agent-go || { fail "source:sentry a#104 gets agent-go with --include-sentry"; rc=1; }
  grg_has $GRG_A 102 agent-go || { fail "a#102 labelled too"; rc=1; }
  glb_teardown; return $rc
}

test_grg_guard_msall_without_approve_all_labels_nothing_and_says_why() {
  grg_world; local rc=0
  grg_ticket $GRG_A 201 open "agent-proposed" 13
  dg_run "$DG_SPEC_ALL" --now
  assert_eq "$DG_RC" "0" "msall register still succeeds (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_OUT$DG_ERR" "--approve-all" "message explains --approve-all is needed" || rc=1
  grg_has $GRG_A 101 agent-go && { fail "msall without --approve-all labelled a#101"; rc=1; }
  grg_has $GRG_A 102 agent-go && { fail "msall without --approve-all labelled a#102"; rc=1; }
  grg_has $GRG_A 201 agent-go && { fail "msall without --approve-all labelled a#201"; rc=1; }
  assert_ne "$(grg_reg_block | jq -r .go)" "true" "msall without --approve-all: block.go is not true" || rc=1
  glb_teardown; return $rc
}

test_grg_guard_msall_with_approve_all_labels_every_open_milestone() {
  grg_world; local rc=0
  grg_ticket $GRG_A 201 open "agent-proposed" 13
  dg_run "$DG_SPEC_ALL" --approve-all --now
  assert_eq "$DG_RC" "0" "msall --approve-all exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(grg_reg_block | jq -r .go)" "true" "msall --approve-all: block.go is true" || rc=1
  grg_has $GRG_A 102 agent-go || { fail "ms 12 ticket a#102 labelled"; rc=1; }
  grg_has $GRG_A 201 agent-go || { fail "ms 13 ticket a#201 labelled"; rc=1; }
  glb_teardown; return $rc
}

test_grg_guard_closed_ticket_skipped() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_has $GRG_A 102 agent-go || { fail "positive control: open a#102 labelled"; rc=1; }
  grg_has $GRG_A 103 agent-go && { fail "closed a#103 must not get agent-go"; rc=1; }
  glb_teardown; return $rc
}

test_grg_guard_no_duplicate_label_edits() {
  grg_world; local rc=0 w1 w2
  dg_run "$DG_SPEC_MS" --now
  # a#101 and a#102 each got exactly ONE label POST at register; a#105 already had agent-go -> zero
  assert_eq "$(grg_posts_for $GRG_RA 101)" "1" "a#101: one label POST at register" || rc=1
  assert_eq "$(grg_posts_for $GRG_RA 102)" "1" "a#102: one label POST at register" || rc=1
  assert_eq "$(grg_posts_for $GRG_RA 105)" "0" "a#105 already had agent-go: no label POST" || rc=1
  grg_cache_registered
  glb_sync; w1=$(dg_writes)
  glb_sync; w2=$(dg_writes)
  assert_eq "$w2" "$w1" "a second sync writes nothing" || rc=1
  assert_eq "$(grg_posts_for $GRG_RA 101)" "1" "a#101: still one label POST after syncs" || rc=1
  glb_teardown; return $rc
}

test_grg_guard_stripped_agent_go_not_relabelled_but_new_arrival_is() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_has $GRG_A 102 agent-go || { fail "precondition: a#102 granted at register"; rc=1; }
  glb_strip_label $GRG_A 102 agent-go
  grg_ticket $GRG_A 106 open "agent-proposed" 12      # arrives after JP's registration
  grg_cache_registered
  glb_sync
  grg_has $GRG_A 106 agent-go || { fail "positive control: new arrival a#106 labelled by the sync"; rc=1; }
  grg_has $GRG_A 102 agent-go && { fail "sync re-added the agent-go JP removed from a#102"; rc=1; }
  glb_sync
  grg_has $GRG_A 102 agent-go && { fail "second sync re-added the agent-go JP removed"; rc=1; }
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC3: goal_sync for milestone goals

test_grg_sync_grants_ticket_added_to_milestone_after_registration() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_ticket $GRG_A 106 open "agent-proposed" 12     # added later, same milestone
  grg_ticket $GRG_A 107 open "agent-proposed" 20     # other milestone: not in scope
  grg_ticket $GRG_A 108 closed "" 12                 # closed: skipped
  grg_ticket $GRG_A 109 open "source:sentry" 12      # sentry: skipped
  grg_cache_registered
  glb_sync
  assert_eq "$DG_RC" "0" "goal_sync exits 0 (stderr: $DG_ERR)" || rc=1
  grg_has $GRG_A 106 agent-go || { fail "a#106 added after registration gets agent-go"; rc=1; }
  grg_has $GRG_A 106 agent-proposed && { fail "a#106 loses agent-proposed"; rc=1; }
  grg_has $GRG_A 107 agent-go && { fail "a#107 (other milestone) must not be labelled"; rc=1; }
  grg_has $GRG_A 108 agent-go && { fail "closed a#108 must not be labelled"; rc=1; }
  grg_has $GRG_A 109 agent-go && { fail "sentry a#109 must not be labelled"; rc=1; }
  assert_eq "$(grg_reg_block | jq -r --arg a "$GRG_RA#106" '(.granted // []) | index($a) != null')" "true" "granted gains a#106 in the block" || rc=1
  glb_teardown; return $rc
}

test_grg_sync_grants_ticket_goal_when_ticket_becomes_open_after_registration() {   # AC3, #N scope
  grg_world; local rc=0
  grg_ticket $GRG_A 7 closed "" ""                    # closed at registration -> skipped, not in granted
  dg_run "$DG_SPEC_T7" --now
  assert_eq "$(grg_reg_block | jq -r .go)" "true" "#N goal: block.go is true" || rc=1
  grg_has $GRG_A 7 agent-go && { fail "precondition: closed a#7 not labelled at registration"; rc=1; }
  grg_ticket $GRG_A 7 open "agent-proposed" ""        # reopened and proposed after JP's registration
  grg_cache_registered
  glb_sync
  assert_eq "$DG_RC" "0" "goal_sync exits 0 (stderr: $DG_ERR)" || rc=1
  grg_has $GRG_A 7 agent-go || { fail "#N goal: a#7 gets agent-go from the sync"; rc=1; }
  grg_has $GRG_A 7 agent-proposed && { fail "#N goal: a#7 loses agent-proposed"; rc=1; }
  assert_eq "$(grg_reg_block | jq -r --arg a "$GRG_RA#7" '(.granted // []) | index($a) != null')" "true" "#N goal: granted gains a#7 in the block" || rc=1
  glb_teardown; return $rc
}

test_grg_sync_survives_body_rewrite() {   # the whole point: go is in the block, so a registry body rewrite keeps it
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_ticket $GRG_A 106 open "agent-proposed" 12
  grg_cache_registered
  glb_sync
  assert_eq "$(grg_reg_block | jq -r .go)" "true" "block.go still true after a sync rewrote the body" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC4: goal_milestone_approved reads block.go (see also test-goal-inherit-approval.sh)

test_grg_appr_no_approved_by_in_scripts_or_agents() {
  local root out; root=$(cd "$DG_SKILL/../.." && pwd)
  out=$(grep -rn "Approved-by" "$root"/skills/orchestrate/*.sh "$root"/agents/ 2>/dev/null)
  assert_eq "$out" "" "no 'Approved-by' in skills/orchestrate/*.sh or agents/"
}

# ------------------------------------------------------------------ AC6: regression (green by design)

test_grg_waiting_proposed_without_agent_go_is_waiting_jp() {
  grg_world; local rc=0
  dg_lib 'goal_ticket_state example-owner/project-a 101'
  assert_eq "$DG_OUT" "waiting_jp" "agent-proposed without agent-go classes waiting_jp (goal-lib.sh:412-420 unchanged)" || rc=1
  dg_lib 'goal_ticket_state example-owner/project-a 105'
  assert_eq "$DG_OUT" "active" "control: agent-go ticket (no proposed) is active" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC7: launch permission only

test_grg_gates_register_writes_only_agent_go_labels_and_no_graphql() {
  grg_world; local rc=0 bad
  dg_run "$DG_SPEC_MS" --now
  bad=$(grep "POST repos/$GRG_RA/issues/[0-9]*/labels" "$DG_BIN/writes.log" | grep -v '"labels":\["agent-go"\]')
  assert_eq "$bad" "" "every ticket label POST carries exactly [agent-go]" || rc=1
  assert_ne "$(grep -c "POST repos/$GRG_RA/issues/[0-9]*/labels" "$DG_BIN/writes.log")" "0" "positive control: some ticket was labelled" || rc=1
  assert_eq "$(glb_calls_not_api)" "0" "no non-REST (gh pr / gh issue / GraphQL) call" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC8: failed label write is logged

test_grg_log_failed_label_write_at_register() {
  grg_world; local rc=0
  grg_fail_label_post 101
  dg_run "$DG_SPEC_MS" --now
  assert_contains "$DG_ERR" "repo=$GRG_RA issue=101 reason=" "failed label write logs repo, issue, reason" || rc=1
  assert_not_contains "$DG_ERR" "$GRG_SECRET_BODY" "log carries no ticket body" || rc=1
  assert_eq "$(grg_reg_block | jq -r --arg a "$GRG_RA#101" '(.granted // []) | index($a) != null')" "false" "failed a#101 is not recorded as granted (retried next sync)" || rc=1
  grg_has $GRG_A 102 agent-go || { fail "other tickets are still labelled"; rc=1; }
  glb_teardown; return $rc
}

test_grg_log_failed_label_write_at_sync() {
  grg_world; local rc=0
  dg_run "$DG_SPEC_MS" --now
  grg_ticket $GRG_A 106 open "agent-proposed" 12
  grg_fail_label_post 106
  grg_cache_registered
  glb_sync
  assert_contains "$(grg_slog)" "repo=$GRG_RA issue=106 reason=" "sync: failed label write logs repo, issue, reason" || rc=1
  assert_eq "$(grg_reg_block | jq -r --arg a "$GRG_RA#106" '(.granted // []) | index($a) != null')" "false" "sync: failed a#106 not recorded as granted" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC9: v1 goals without go are not migrated (green by design)

test_grg_v1_goal_without_go_grants_nothing_on_sync() {
  grg_world; local rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 900 "$DG_SPEC_MS" host-a active
  grg_cache_registered
  glb_sync
  assert_eq "$(grg_reg_block | jq -r '.go // "absent"')" "absent" "v1 block still has no go field" || rc=1
  grg_has $GRG_A 101 agent-go && { fail "v1 goal without go: sync labelled a#101"; rc=1; }
  grg_has $GRG_A 102 agent-go && { fail "v1 goal without go: sync labelled a#102"; rc=1; }
  assert_eq "$(grg_posts_for $GRG_RA 101)" "0" "no label write at all" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC10: IF IT WORKS

test_grg_launch_registered_goal_is_not_waiting_on_jp_and_launches() {
  grg_world; local rc=0 ga gw
  # control: BEFORE registration the same scope reads as waiting on JP (agent-proposed, no agent-go)
  dg_lib 'goal_eval x '"$DG_SPEC_MS"'; echo "$GE_WAITING"'
  assert_ne "$DG_OUT" "0" "control: unregistered scope has waiting tickets" || rc=1
  dg_run "$DG_SPEC_MS" --now
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  dg_lib 'goal_eval "'"$DG_ID_MS"'" "'"$DG_SPEC_MS"'"; echo "$GE_WAITING $GE_ACTIVE"'
  gw=${DG_OUT%% *}; ga=${DG_OUT##* }
  # open in-scope after register: 101,102 labelled agent-go (active), 105 agent-go (active), 104 sentry stays agent-proposed
  # without agent-go -> 1 waiting; so the goal still has active tickets and the waiting set holds only the sentry ticket.
  assert_eq "$gw" "1" "only the guarded sentry ticket is still waiting on JP" || rc=1
  assert_eq "$ga" "3" "a#101, a#102, a#105 are active (not waiting on JP)" || rc=1
  dg_wait_claude 1 || { fail "the goal's lead launched without anyone hand-labelling a ticket"; rc=1; }
  glb_teardown; return $rc
}

test_grg_launch_no_waiting_slog_line_for_newly_registered_goal() {
  grg_world; local rc=0
  grg_ticket $GRG_A 104 open "" 12           # drop the guarded sentry ticket's label so every open ticket is launchable
  dg_run "$DG_SPEC_MS" --now
  dg_lib 'goal_eval "'"$DG_ID_MS"'" "'"$DG_SPEC_MS"'"; echo "$GE_WAITING"'
  assert_eq "$DG_OUT" "0" "no ticket of the new goal is waiting on JP, so no '[goal] <id> waiting on JP (N ticket(s))' line is possible" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC15: captured error event

test_grg_capture_failed_label_write_is_captured_without_secrets() {
  grg_world; local rc=0 ev
  dg_run "$DG_SPEC_MS" --now
  grg_ticket $GRG_A 106 open "agent-proposed" 12 "$GRG_SECRET_BODY"
  grg_fail_label_post 106
  grg_cache_registered
  GH_TOKEN="ghp_GRGSECRETTOKEN" glb_sync
  ev=$(glb_events | jq -c 'select(.event == "error")' 2>/dev/null)
  assert_ne "$ev" "" "an error event was captured for the failed label write" || rc=1
  assert_eq "$(printf '%s' "$ev" | jq -rs 'map(select((.route // "") | startswith("supervisor/goal"))) | length > 0')" "true" "event carries the supervisor/goal route" || rc=1
  assert_eq "$(printf '%s' "$ev" | jq -rs 'map(select((.release // "") != "")) | length > 0')" "true" "event carries a release" || rc=1
  assert_not_contains "$(glb_events)" "$GRG_SECRET_BODY" "event holds no ticket body" || rc=1
  assert_not_contains "$(glb_events)" "ghp_GRGSECRETTOKEN" "event holds no token" || rc=1
  glb_teardown; return $rc
}

for t in test_grg_reg_milestone_goal_writes_go_granted_and_labels \
         test_grg_reg_ticket_goal_writes_go_and_labels \
         test_grg_reg_queued_goal_also_records_go \
         test_grg_guard_business_intelligence_never_labelled \
         test_grg_guard_sentry_skipped_without_flag \
         test_grg_guard_sentry_labelled_with_include_sentry \
         test_grg_guard_msall_without_approve_all_labels_nothing_and_says_why \
         test_grg_guard_msall_with_approve_all_labels_every_open_milestone \
         test_grg_guard_closed_ticket_skipped \
         test_grg_guard_no_duplicate_label_edits \
         test_grg_guard_stripped_agent_go_not_relabelled_but_new_arrival_is \
         test_grg_sync_grants_ticket_added_to_milestone_after_registration \
         test_grg_sync_grants_ticket_goal_when_ticket_becomes_open_after_registration \
         test_grg_sync_survives_body_rewrite \
         test_grg_appr_no_approved_by_in_scripts_or_agents \
         test_grg_waiting_proposed_without_agent_go_is_waiting_jp \
         test_grg_gates_register_writes_only_agent_go_labels_and_no_graphql \
         test_grg_log_failed_label_write_at_register \
         test_grg_log_failed_label_write_at_sync \
         test_grg_v1_goal_without_go_grants_nothing_on_sync \
         test_grg_launch_registered_goal_is_not_waiting_on_jp_and_launches \
         test_grg_launch_no_waiting_slog_line_for_newly_registered_goal \
         test_grg_capture_failed_label_write_is_captured_without_secrets; do
  run_test "$t"
done
