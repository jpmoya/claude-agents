# #313 — registering a goal is JP's go: deliver.sh cmd_register labels in-scope tickets agent-go (+ guards);
# goal-lib classes an agent-proposed ticket of an approved goal `active`.
#   AC1 six fixtures   AC2 approval line   AC3 idempotent   AC4 (existing suites untouched)   AC5 JP-only gates   AC6 slog
# Expected values come from the ticket body (Decided design / Decisions) — never from the code.
# Reuses the dg_ (deliver) and gs_ (supervisor) sandboxes; when this file runs alone they are sourced first.
# Prefixed ga_ / GA_. CLI shape assumed: `deliver.sh <goal> [--include-sentry] [--approve-all] [instructions…]`.
GA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
type dg_setup >/dev/null 2>&1 || . "$GA_DIR/test-goal-deliver.sh"
type gs_env   >/dev/null 2>&1 || . "$GA_DIR/test-goal-supervisor.sh"

GA_PA="example-owner_project-a"
GA_BI="example-owner_Business-Intelligence"
GA_NOTE_RE='^\*\*\[delivery-lead\] NOTE\*\* agent-go added: goal '

# ga_world — dg sandbox plus milestone 12 = {101 open plain, 102 closed, 103 PR, 104 open agent-proposed, 105 open agent-go}
ga_world() {
  dg_setup
  dg_issue $GA_PA 104 open 12; dg_issue $GA_PA 105 open 12
  ga_labels $GA_PA 104 agent-proposed; ga_labels $GA_PA 105 agent-go
}
ga_labels() {  # <rk> <n> <label…> — set the label list of a fixture issue
  local rk=$1 n=$2 f l; shift 2; f="$DG_ST/issues/$rk/$n.json"
  l=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  jq -c --argjson l "$l" '.labels = ($l | map({name:.}))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
ga_has() { dg_has_label "$DG_ST/issues/$1/$2.json" "$3"; }
ga_comments() { jq -r '.[].body' "$DG_ST/comments/$1-$2.json" 2>/dev/null; }
ga_note_count() { ga_comments "$1" "$2" | grep -c 'agent-go added' || true; }
ga_label_posts() {  # <owner/repo> <n> — POSTs of labels to that ticket
  grep -c "^POST repos/$1/issues/$2/labels " "$DG_BIN/writes.log" || true
}
ga_touched() { grep -c "repos/$1/issues/$2[/ ]" "$DG_BIN/writes.log" || true; }  # any write at all to the ticket
ga_slog() { cat "$DG_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
ga_reg_body() { jq -r .body "$(dg_reg_file_for "$1")"; }
ga_add_bi() {  # Business-Intelligence repo in DISPATCH_REPOS with milestone 3 = {5 open}
  local ck="$DG_HOME/checkouts/Business-Intelligence"
  fixture_repo "$ck" example-owner/Business-Intelligence
  printf 'DISPATCH_REPOS+=("example-owner/Business-Intelligence:%s")\n' "$(cd "$ck" && pwd -P)" >> "$DG_HOME/.claude/pipeline/config.local.sh"
  mkdir -p "$DG_ST/issues/$GA_BI"
  dg_milestone $GA_BI 3 "bi ms"; dg_issue $GA_BI 5 open 3
}

# ---------------------------------------------------------------- AC1 fixtures 1 + 5: labelling, skips ----------

# Hand: open in ms-12 = 101, 104, 105. 105 already agent-go → untouched. 101, 104 get agent-go; 104 loses agent-proposed.
# 102 (closed) and 103 (a PR) are never touched.
test_ga_fixture1_labels_open_tickets_and_skips_already_go() {
  ga_world
  local rc=0
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  ga_has $GA_PA 101 agent-go || { fail "101 labelled agent-go"; rc=1; }
  ga_has $GA_PA 104 agent-go || { fail "104 labelled agent-go"; rc=1; }
  ga_has $GA_PA 104 agent-proposed && { fail "104 loses agent-proposed"; rc=1; }
  assert_eq "$(ga_touched example-owner/project-a 105)" "0" "105 (already agent-go) gets no write at all" || rc=1
  assert_eq "$(ga_note_count $GA_PA 105)" "0" "105 gets no comment" || rc=1
  assert_eq "$(ga_touched example-owner/project-a 102)" "0" "fixture 5: closed 102 gets no write" || rc=1
  ga_has $GA_PA 102 agent-go && { fail "closed 102 not labelled"; rc=1; }
  assert_eq "$(ga_touched example-owner/project-a 103)" "0" "PR 103 gets no write" || rc=1
  dg_teardown; return $rc
}

# Decisions: each labelled ticket gets exactly one NOTE with the pinned text.
test_ga_labelled_ticket_gets_one_note_with_goal_id() {
  ga_world
  local rc=0
  dg_run "$DG_SPEC_MS"
  assert_eq "$(ga_note_count $GA_PA 101)" "1" "101: exactly one note" || rc=1
  assert_eq "$(ga_comments $GA_PA 101 | grep -c "^\*\*\[delivery-lead\] NOTE\*\* agent-go added: goal $DG_ID_MS registered by JP\$")" "1" \
    "101: note text is '**[delivery-lead] NOTE** agent-go added: goal <id> registered by JP'" || rc=1
  assert_eq "$(ga_note_count $GA_PA 104)" "1" "104: exactly one note" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC1 fixture 2: Business-Intelligence ----------

test_ga_fixture2_business_intelligence_never_labelled() {
  ga_world; ga_add_bi
  local rc=0
  dg_run "example-owner/Business-Intelligence:milestone:3" --include-sentry --approve-all
  assert_eq "$DG_RC" "0" "BI goal still registers (stderr: $DG_ERR)" || rc=1
  assert_eq "$(ga_touched example-owner/Business-Intelligence 5)" "0" "BI ticket gets no write even with every flag" || rc=1
  ga_has $GA_BI 5 agent-go && { fail "BI ticket not labelled"; rc=1; }
  assert_eq "$(ga_note_count $GA_BI 5)" "0" "BI ticket gets no comment" || rc=1
  # AC6: the skip is logged with repo + issue
  assert_contains "$(ga_slog)" "Business-Intelligence" "slog names the repo" || rc=1
  ga_slog | grep 'Business-Intelligence' | grep -q '5' || { fail "slog line carries the issue number 5"; rc=1; }
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC1 fixture 3: source:sentry -------------------

test_ga_fixture3_sentry_ticket_skipped_by_default() {
  ga_world; ga_labels $GA_PA 101 source:sentry
  local rc=0
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  ga_has $GA_PA 101 agent-go && { fail "sentry ticket 101 not labelled without the flag"; rc=1; }
  assert_eq "$(ga_touched example-owner/project-a 101)" "0" "sentry ticket gets no write" || rc=1
  ga_has $GA_PA 104 agent-go || { fail "non-sentry 104 still labelled"; rc=1; }
  assert_contains "$(ga_slog)" "101" "AC6: slog line for the skipped sentry ticket" || rc=1
  dg_teardown; return $rc
}

test_ga_fixture3_sentry_ticket_labelled_with_include_sentry() {
  ga_world; ga_labels $GA_PA 101 source:sentry
  local rc=0
  dg_run "$DG_SPEC_MS" --include-sentry
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  ga_has $GA_PA 101 agent-go || { fail "sentry ticket 101 labelled with --include-sentry"; rc=1; }
  ga_has $GA_PA 101 source:sentry || { fail "source:sentry label kept"; rc=1; }
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC1 fixture 4: milestones:all gate -------------

# Hand: msall scope = open milestones 12 and 13 → open tickets 101, 104, 105 (12) and 201 (13).
test_ga_fixture4_msall_without_approve_all_registers_but_labels_nothing() {
  ga_world
  local rc=0 out
  dg_run "$DG_SPEC_ALL"
  out="$DG_OUT $DG_ERR"
  assert_eq "$DG_RC" "0" "goal still registers (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "registry issue created" || rc=1
  assert_contains "$out" "--approve-all" "message says why (names --approve-all)" || rc=1
  ga_has $GA_PA 101 agent-go && { fail "101 not labelled"; rc=1; }
  ga_has $GA_PA 201 agent-go && { fail "201 not labelled"; rc=1; }
  ga_has $GA_PA 104 agent-go && { fail "104 not labelled"; rc=1; }
  assert_eq "$(grep -c 'repos/example-owner/project-a/issues/' "$DG_BIN/writes.log" || true)" "0" "zero writes to any project-a ticket" || rc=1
  assert_eq "$(ga_reg_body "$DG_ID_ALL" | grep -c '^Approved-by:' || true)" "0" "no approval line (behaves as today)" || rc=1
  assert_contains "$(ga_slog)" "approve-all" "AC6: refusal logged with its reason" || rc=1
  assert_contains "$(ga_slog)" "example-owner/project-a" "AC6: refusal log names the repo" || rc=1
  dg_teardown; return $rc
}

test_ga_msall_with_approve_all_labels_every_open_ticket() {
  ga_world
  local rc=0 n
  dg_run "$DG_SPEC_ALL" --approve-all
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  for n in 101 104 105; do ga_has $GA_PA $n agent-go || { fail "$n labelled"; rc=1; }; done
  ga_has $GA_PA 201 agent-go || { fail "201 (milestone 13) labelled"; rc=1; }
  assert_eq "$(ga_reg_body "$DG_ID_ALL" | grep -c '^Approved-by: JP' || true)" "1" "approval line present" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- ticket-kind goals ------------------------------

test_ga_ticket_goal_labels_the_ticket() {
  ga_world
  local rc=0
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  ga_has $GA_PA 7 agent-go || { fail "ticket 7 labelled agent-go"; rc=1; }
  ga_has $GA_PA 8 agent-go && { fail "ticket 8 (out of scope) untouched"; rc=1; }
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC2: registry block ----------------------------

test_ga_ac2_registry_body_has_approval_line_scope_and_json() {
  ga_world
  local rc=0 body
  dg_run "$DG_SPEC_MS"
  body=$(ga_reg_body "$DG_ID_MS")
  printf '%s\n' "$body" | grep -Eq '^Approved-by: JP \(register [0-9]{4}-[0-9]{2}-[0-9]{2}[^)]*\)$' \
    || { fail "body has line 'Approved-by: JP (register <ISO date>)'; body: $body"; rc=1; }
  assert_contains "$body" "example-owner/project-a#101" "scope list names 101" || rc=1
  assert_contains "$body" "example-owner/project-a#104" "scope list names 104" || rc=1
  assert_contains "$body" "example-owner/project-a#105" "scope list names 105" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r .id)" "$DG_ID_MS" "JSON block still parses with the id" || rc=1
  assert_eq "$(printf '%s\n' "$body" | head -1)" "Goal: $DG_SPEC_MS" "body line 1 unchanged" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC3: idempotent --------------------------------

test_ga_ac3_second_register_after_stop_adds_no_edits_or_comments() {
  ga_world
  local rc=0
  dg_run "$DG_SPEC_MS"; dg_run stop "$DG_ID_MS"
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "re-register after stop exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(ga_label_posts example-owner/project-a 101)" "1" "101: one label POST in total" || rc=1
  assert_eq "$(ga_label_posts example-owner/project-a 104)" "1" "104: one label POST in total" || rc=1
  assert_eq "$(ga_note_count $GA_PA 101)" "1" "101: still one note" || rc=1
  assert_eq "$(ga_note_count $GA_PA 104)" "1" "104: still one note" || rc=1
  dg_teardown; return $rc
}

test_ga_ac3_refused_second_register_adds_no_edits_or_comments() {
  ga_world
  local rc=0 before after
  dg_run "$DG_SPEC_MS"
  before=$(grep -c "repos/example-owner/project-a/issues/" "$DG_BIN/writes.log" || true)
  dg_run "$DG_SPEC_MS"
  after=$(grep -c "repos/example-owner/project-a/issues/" "$DG_BIN/writes.log" || true)
  assert_ne "$before" "0" "first register did write to the tickets (precondition)" || rc=1
  assert_eq "$after" "$before" "no further ticket writes on a second register" || rc=1
  assert_eq "$(ga_note_count $GA_PA 101)" "1" "101: still one note" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- Decisions: one failed edit does not fail register

test_ga_label_failure_logged_and_registration_continues() {
  ga_world
  mv "$DG_BIN/gh" "$DG_BIN/gh.real"
  cat > "$DG_BIN/gh" <<'GA_WRAP'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in *"repos/example-owner/project-a/issues/101/labels"*) echo "gh: boom (HTTP 500)" >&2; exit 1 ;; esac
exec "$HERE/gh.real" "$@"
GA_WRAP
  chmod +x "$DG_BIN/gh"
  local rc=0
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "registration does not fail (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "registry issue exists" || rc=1
  ga_has $GA_PA 104 agent-go || { fail "the other ticket (104) is still labelled"; rc=1; }
  ga_has $GA_PA 101 agent-go && { fail "101 (failed edit) not labelled"; rc=1; }
  ga_slog | grep 'example-owner/project-a' | grep -q '101' || { fail "AC6: slog line with repo + issue 101 for the failed edit"; rc=1; }
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC5: JP-only gates unchanged ------------------

test_ga_ac5_register_adds_only_agent_go_and_one_note_shape() {
  ga_world
  local rc=0 n after
  for n in 101 104 105 102; do jq -c '[.labels[].name] | sort' "$DG_ST/issues/$GA_PA/$n.json" > "$DG_HOME/before-$n"; done
  dg_run "$DG_SPEC_MS"
  for n in 101 104 105 102; do
    after=$(jq -c '[.labels[].name] | sort' "$DG_ST/issues/$GA_PA/$n.json")
    # hand: only agent-go may be added, only agent-proposed may be removed
    jq -e --argjson a "$after" '. as $b | ((($a - $b) - ["agent-go"]) == []) and ((($b - $a) - ["agent-proposed"]) == [])' "$DG_HOME/before-$n" >/dev/null \
      || { fail "ticket $n: label change beyond +agent-go / -agent-proposed (after: $after)"; rc=1; }
  done
  assert_eq "$(ga_note_count $GA_PA 101)" "1" "101 got its NOTE (precondition: labelling ran)" || rc=1
  for n in 101 104; do
    ga_comments $GA_PA $n | grep -v "$GA_NOTE_RE" | grep -q . && { fail "ticket $n: a comment other than the agent-go NOTE was posted"; rc=1; }
  done
  dg_teardown; return $rc
}

test_ga_ac5_no_gate_answering_code_path_in_deliver() {
  local s pat rc=0
  s=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  # The change must label agent-go (launch permission) only: deliver.sh must never post/answer a JP gate.
  grep -q 'agent-go' "$s/deliver.sh" || { fail "precondition: deliver.sh handles agent-go"; rc=1; }
  for pat in 'JP CONFIRMED' 'DECISION\*\*' 'go-staging' 'agent-approved' 'Scope: staging-only' 'MOCKUPS APPROVED' 'EFFORT APPROVED'; do
    if grep -q -- "$pat" "$s/deliver.sh"; then fail "deliver.sh must not reference '$pat' (would answer a JP-only gate)"; rc=1; fi
  done
  return $rc
}

# ---------------------------------------------------------------- AC1 fixture 6 / AC5: goal-lib classification -----

# ga_classify <approval line|""> <ticket labels csv> <comment…> — single-ticket goal t-7 in a launch-eligible shape;
# prints delivered | waiting_jp | active | none (same read-out as gs_classify). Writes the registry comments to $GA_CARDS_F.
ga_classify() {
  local appr=$1 lb=$2 b out=none f
  shift 2
  gs_env
  gs_issue 7 open "" "" "$lb"
  rm -f "$GS_ST/comments/$GS_A-7.json"
  for b in "$@"; do gs_comment 7 "$b"; done
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  if [ -n "$appr" ]; then
    f=$(gs_regfile 50)
    jq -c --arg l "$appr" '.body = (.body + "\n" + $l + "\n")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
  gs_tick
  if [ "$(gs_reg_state 50)" = closed ] && ! gs_has_label 50 goal-stopped; then out=delivered
  elif gs_has_label 50 goal-waiting-jp; then out=waiting_jp
  elif gs_wait_claude 1; then out=active
  fi
  gs_reg_comments 50 > "$GA_CARDS_F"
  gs_cleanup
  printf '%s' "$out"
}
GA_CARDS_F=$(mktemp)
GA_READY=$'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
GA_APPR='Approved-by: JP (register 2026-10-16)'

test_ga_fixture6_approved_goal_agent_proposed_ticket_is_active() {
  assert_eq "$(ga_classify "$GA_APPR" "agent-proposed" "$GA_READY")" "active" \
    "approved goal + agent-proposed, no agent-go → active" || return 1
}

test_ga_fixture6_unapproved_goal_agent_proposed_ticket_stays_waiting_jp() {
  assert_eq "$(ga_classify "" "agent-proposed" "$GA_READY")" "waiting_jp" "non-approved goal → waiting_jp (regression)" || return 1
}

test_ga_unapproved_goal_card_says_not_approved_yet() {
  # the status text (reason) travels via the registry waiting card; run in-process through the supervisor tick
  local out
  out=$(ga_classify "" "agent-proposed" "$GA_READY")
  assert_eq "$out" "waiting_jp" "non-approved goal parks (precondition)" || return 1
  assert_contains "$(cat "$GA_CARDS_F")" "not approved yet" "reason text 'not approved yet' still shown" || return 1
}

test_ga_approved_by_someone_other_than_jp_does_not_approve() {
  assert_eq "$(ga_classify 'Approved-by: Bob (register 2026-10-16)' "agent-proposed" "$GA_READY")" "waiting_jp" \
    "only 'Approved-by: JP' approves" || return 1
}

test_ga_approved_goal_never_reports_not_approved_yet() {
  local out
  out=$(ga_classify "$GA_APPR" "agent-proposed" "$GA_READY")
  assert_eq "$out" "active" "approved goal runs (precondition)" || return 1
  assert_not_contains "$(cat "$GA_CARDS_F")" "not approved yet" "approved goal never says 'not approved yet'" || return 1
}

# AC5: approval of a goal answers launch permission only — gates still park the ticket.
test_ga_ac5_approved_goal_still_parks_on_jp_only_gates() {
  assert_eq "$(ga_classify "$GA_APPR" "agent-proposed" $'**[infra-operator] AWAITING GO**\nplan ready')" "waiting_jp" "AWAITING GO still waits" || return 1
  assert_eq "$(ga_classify "$GA_APPR" "agent-proposed" $'**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nsee mockups')" "waiting_jp" "mockup approval still waits" || return 1
  assert_eq "$(ga_classify "$GA_APPR" "agent-proposed" $'**[deployer] DEPLOYED TO STAGING**\nup')" "waiting_jp" "promotion still waits" || return 1
  assert_eq "$(ga_classify "$GA_APPR" "agent-proposed" $'**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp\nx')" "waiting_jp" "needs_jp still waits" || return 1
}

for t in \
  test_ga_fixture1_labels_open_tickets_and_skips_already_go test_ga_labelled_ticket_gets_one_note_with_goal_id \
  test_ga_fixture2_business_intelligence_never_labelled \
  test_ga_fixture3_sentry_ticket_skipped_by_default test_ga_fixture3_sentry_ticket_labelled_with_include_sentry \
  test_ga_fixture4_msall_without_approve_all_registers_but_labels_nothing test_ga_msall_with_approve_all_labels_every_open_ticket \
  test_ga_ticket_goal_labels_the_ticket \
  test_ga_ac2_registry_body_has_approval_line_scope_and_json \
  test_ga_ac3_second_register_after_stop_adds_no_edits_or_comments test_ga_ac3_refused_second_register_adds_no_edits_or_comments \
  test_ga_label_failure_logged_and_registration_continues \
  test_ga_ac5_register_adds_only_agent_go_and_one_note_shape test_ga_ac5_no_gate_answering_code_path_in_deliver \
  test_ga_fixture6_approved_goal_agent_proposed_ticket_is_active test_ga_fixture6_unapproved_goal_agent_proposed_ticket_stays_waiting_jp \
  test_ga_unapproved_goal_card_says_not_approved_yet \
  test_ga_approved_by_someone_other_than_jp_does_not_approve test_ga_approved_goal_never_reports_not_approved_yet \
  test_ga_ac5_approved_goal_still_parks_on_jp_only_gates; do
  run_test "$t"
done
