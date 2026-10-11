# Issue #192 — rename the project-manager agent to delivery-lead; project-manager stays a thin deprecated alias.
# Expected values are hand-written from the ticket. Every function/variable is prefixed dlr_ / DLR_.
# Sourced by run-tests.sh (lib/assert.sh + lib/fixture.sh already loaded); placeholder repo names only.
#
#   AC1  dlr_ac1_*   agents/delivery-lead.md
#   AC2  dlr_ac2_*   agents/project-manager.md thin alias
#   AC3  dlr_ac3_*   hooks/pipeline-markers.sh vocabulary
#   AC4  dlr_ac4_*   latest_marker (supervisor.sh), rc_gate_facts (reconcile-status.sh), orchestrator.md snippets
#   AC5  (infra/code-track decision validation: terminal_kind.test.sh + test-delegated-decision.sh parallel cases)
#   AC6  dlr_ac6_*   git grep allowlist + prose headings in the four docs

HERE_DLR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DLR=$(cd "$HERE_DLR/../../.." && pwd)
MARKERS_DLR="$ROOT_DLR/hooks/pipeline-markers.sh"
SUP_DLR="$HERE_DLR/../supervisor.sh"
LIB_DLR="$HERE_DLR/../pipeline-lib.sh"
RECON_DLR="$HERE_DLR/../reconcile-status.sh"
ORCH_DLR="$ROOT_DLR/agents/orchestrator.md"
DL_DLR="$ROOT_DLR/agents/delivery-lead.md"
PM_DLR="$ROOT_DLR/agents/project-manager.md"

dlr_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }
dlr_front() { awk '/^---$/ { n++; next } n == 1 { print } n >= 2 { exit }' "$1"; }

# ------------------------------------------------------------------------------------------ AC1

test_dlr_ac1_delivery_lead_file_name_and_prose() {
  [ -f "$DL_DLR" ] || { fail "AC1: agents/delivery-lead.md missing"; return 1; }
  local n lines
  assert_contains "$(dlr_front "$DL_DLR")" "name: delivery-lead" "AC1: frontmatter name" || return 1
  n=$(grep -ic "project manager\|project-manager" "$DL_DLR")
  assert_le "$n" 1 "AC1: at most one project-manager mention (the 'formerly' line)" || return 1
  if [ "$n" -eq 1 ]; then
    lines=$(grep -i "project manager\|project-manager" "$DL_DLR")
    assert_contains "$lines" "formerly" "AC1: the single mention is a 'formerly project-manager' line" || return 1
  fi
}

test_dlr_ac1_delivery_lead_markers_and_status_card_sentence() {
  [ -f "$DL_DLR" ] || { fail "AC1: agents/delivery-lead.md missing"; return 1; }
  local body; body=$(cat "$DL_DLR")
  assert_contains "$body" '**[delivery-lead] DECISION**' "AC1: DECISION marker example" || return 1
  assert_contains "$body" '**[delivery-lead] JP CONFIRMED**' "AC1: JP CONFIRMED marker example" || return 1
  assert_contains "$body" '**[delivery-lead] NOTE**' "AC1: NOTE marker example" || return 1
  assert_contains "$body" 'Resolves:' "AC1: Resolves rule kept" || return 1
  assert_contains "$body" 'Every status the delivery-lead writes' "AC1: status-card sentence says delivery-lead" || return 1
  assert_not_contains "$body" '[project-manager] DECISION' "AC1: no legacy DECISION example" || return 1
}

test_dlr_ac1_delivery_lead_keeps_model_and_tools() {
  [ -f "$DL_DLR" ] || { fail "AC1: agents/delivery-lead.md missing"; return 1; }
  local f; f=$(dlr_front "$DL_DLR")
  assert_contains "$f" 'model: claude-opus-5-5' "AC1: model unchanged" || return 1
  assert_contains "$f" 'effort: high' "AC1: effort unchanged" || return 1
  assert_contains "$f" 'tools: "*"' "AC1: tools unchanged" || return 1
}

# ------------------------------------------------------------------------------------------ AC2

test_dlr_ac2_alias_is_thin_deprecated_and_points_at_delivery_lead() {
  [ -f "$PM_DLR" ] || { fail "AC2: agents/project-manager.md missing"; return 1; }
  local n f body
  n=$(wc -l < "$PM_DLR" | tr -d ' ')
  assert_le "$n" 15 "AC2: alias is at most 15 lines (got $n)" || return 1
  f=$(dlr_front "$PM_DLR"); body=$(cat "$PM_DLR")
  assert_contains "$f" "name: project-manager" "AC2: alias frontmatter name" || return 1
  assert_contains "$f" "description: \"DEPRECATED alias of delivery-lead" "AC2: description starts with DEPRECATED alias of delivery-lead" || return 1
  assert_contains "$body" "DEPRECATED" "AC2: contains DEPRECATED" || return 1
  assert_contains "$body" "delivery-lead.md" "AC2: references delivery-lead.md" || return 1
  assert_contains "$body" '**[delivery-lead] …**' "AC2: tells the agent to post [delivery-lead] markers" || return 1
}

test_dlr_ac2_alias_has_same_model_and_tools_as_delivery_lead() {
  [ -f "$PM_DLR" ] && [ -f "$DL_DLR" ] || { fail "AC2: alias or delivery-lead file missing"; return 1; }
  local k a b
  for k in model tools; do
    a=$(dlr_front "$PM_DLR" | grep "^$k:"); b=$(dlr_front "$DL_DLR" | grep "^$k:")
    assert_ne "$a" "" "AC2: alias has a $k line" || return 1
    assert_eq "$a" "$b" "AC2: alias $k == delivery-lead $k" || return 1
  done
}

# ------------------------------------------------------------------------------------------ AC3

test_dlr_ac3_markers_for_both_spellings() {
  local dl pm
  dl=$( . "$MARKERS_DLR" && markers_for delivery-lead )
  pm=$( . "$MARKERS_DLR" && markers_for project-manager )
  assert_eq "$dl" "DECISION|JP CONFIRMED" "AC3: markers_for delivery-lead" || return 1
  assert_eq "$pm" "DECISION|JP CONFIRMED" "AC3: markers_for project-manager unchanged" || return 1
}

# dlr_re <agent|""> <first line> → true/false
dlr_re() { ( . "$MARKERS_DLR" && jq -n --arg l "$2" --arg re "$(marker_re ${1:+$1})" '$l | test($re)' ); }

test_dlr_ac3_marker_re_any_agent_matches_both_spellings() {
  local l
  for l in '**[delivery-lead] DECISION**' '**[delivery-lead] JP CONFIRMED**' '**[delivery-lead] DECISION** — merge first' \
           '**[project-manager] DECISION**' '**[project-manager] JP CONFIRMED**'; do
    assert_eq "$(dlr_re "" "$l")" "true" "AC3: marker_re must match [$l]" || return 1
  done
}

test_dlr_ac3_marker_re_any_agent_rejects_invalid_delivery_lead_forms() {
  local l
  for l in '**[delivery-lead] NOTE**' '**[delivery-lead] BLOCKED**' '**[delivery-lead] GO**' '**[delivery-lead] MOCKUPS APPROVED**' \
           '**[delivery-leader] DECISION**' '**[delivery lead] DECISION**'; do
    assert_eq "$(dlr_re "" "$l")" "false" "AC3: marker_re must NOT match [$l]" || return 1
  done
}

test_dlr_ac3_marker_re_scoped_to_delivery_lead() {
  local l
  for l in '**[delivery-lead] DECISION**' '**[delivery-lead] JP CONFIRMED**'; do
    assert_eq "$(dlr_re delivery-lead "$l")" "true" "AC3: marker_re delivery-lead matches [$l]" || return 1
  done
  for l in '**[delivery-lead] NOTE**' '**[delivery-lead] BLOCKED**' '**[delivery-lead] GO**' '**[delivery-lead] PASS**' '**[project-manager] DECISION**'; do
    assert_eq "$(dlr_re delivery-lead "$l")" "false" "AC3: marker_re delivery-lead must NOT match [$l]" || return 1
  done
}

test_dlr_ac3_other_vocabulary_unchanged() {
  assert_eq "$( . "$MARKERS_DLR" && markers_for jp )" "GO|MOCKUPS APPROVED" "AC3: jp unchanged" || return 1
  assert_eq "$( . "$MARKERS_DLR" && markers_for code-reviewer )" "PASS|FAIL|BLOCKED" "AC3: code-reviewer unchanged" || return 1
}

# ------------------------------------------------------------------------------------------ AC4

# dlr_latest <body>... — runs supervisor.sh's latest_marker against a fake gh serving the comments (oldest -> newest)
dlr_latest() {
  local tmp arr='[]' b i=0 out
  tmp=$(mktemp -d)
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "$(printf '2026-10-01T12:%02d:00Z' "$i")" '. + [{body: $b, createdAt: $t}]')
  done
  printf '{"comments":%s}' "$arr" > "$tmp/case.json"
  mkdir -p "$tmp/bin" "$tmp/repo"
  cat > "$tmp/bin/gh" <<'SH'
#!/bin/bash
args=("$@"); jq_expr=""
for ((i=0;i<${#args[@]};i++)); do case "${args[i]}" in --jq|-q) jq_expr=${args[i+1]};; esac; done
if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "$CASE_JSON"; else cat "$CASE_JSON"; fi
SH
  chmod +x "$tmp/bin/gh"
  out=$(
    export CASE_JSON="$tmp/case.json" PATH="$tmp/bin:$PATH"
    . "$MARKERS_DLR"
    eval "$(dlr_fn "$LIB_DLR" marker_last_jq)"
    eval "$(dlr_fn "$SUP_DLR" latest_marker)"
    latest_marker "$tmp/repo" 42
  )
  rm -rf "$tmp"
  printf '%s' "$out"
}

DLR_DEC=$'**[delivery-lead] DECISION**\nResolves: https://example.test/c/1\nDo X.'

test_dlr_ac4_latest_marker_decision_is_second_line_gate_stays() {
  local out
  out=$(dlr_latest '**[code-reviewer] PASS**' "$DLR_DEC")
  assert_eq "$out" $'**[code-reviewer] PASS**\n**[delivery-lead] DECISION**' "AC4: gate = code-reviewer PASS on line 1; the decision's first line on line 2" || return 1
}

test_dlr_ac4_latest_marker_legacy_decision_unchanged() {
  local out dec=$'**[project-manager] DECISION**\nResolves: https://example.test/c/1\nDo X.'
  out=$(dlr_latest '**[code-reviewer] PASS**' "$dec")
  assert_eq "$out" $'**[code-reviewer] PASS**\n**[project-manager] DECISION**' "AC4: legacy spelling behaves as before" || return 1
}

test_dlr_ac4_latest_marker_delivery_lead_note_is_inert() {
  local out
  out=$(dlr_latest '**[code-reviewer] PASS**' $'**[delivery-lead] NOTE**\nstatus')
  assert_eq "$out" '**[code-reviewer] PASS**' "AC4: NOTE is not a routing marker, no 2nd line" || return 1
}

test_dlr_ac4_latest_marker_invalid_delivery_lead_forms_are_inert() {
  local out l
  for l in '**[delivery-lead] BLOCKED**' '**[delivery-leader] DECISION**'; do
    out=$(dlr_latest '**[code-reviewer] PASS**' "$l")
    assert_eq "$out" '**[code-reviewer] PASS**' "AC4: [$l] is inert" || return 1
  done
}

test_dlr_ac4_latest_marker_delivery_lead_alone_is_never_the_gate() {
  local out
  out=$(dlr_latest '**[deployer] BLOCKED**' "$DLR_DEC")
  assert_eq "$(printf '%s' "$out" | head -1)" '**[deployer] BLOCKED**' "AC4: gate stays the BLOCKED" || return 1
}

# dlr_facts <body>... — full rc_gate_facts TSV line from reconcile-status.sh (comments dated 1 minute apart, oldest first)
dlr_facts() {
  local arr='[]' b i=0 json
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "$(printf '2026-10-01T12:%02d:00Z' "$i")" '. + [{body: $b, createdAt: $t}]')
  done
  json=$(jq -n --argjson c "$arr" '{comments: $c}')
  (
    . "$MARKERS_DLR"
    eval "$(dlr_fn "$RECON_DLR" rc_gate_facts)"
    rc_gate_facts "$json"
  )
}

# dlr_answered <body>... — the "answered" field of dlr_facts
dlr_answered() { dlr_facts "$@" | cut -f2; }

# #192 (architect SPEC RESOLVED): a routing marker (DECISION, JP CONFIRMED, [jp] GO) posted after the gate becomes the gate
# itself on main, so answered detection is exercised with free-text replies, as test-status-needs-jp does.
test_dlr_ac4_reconcile_answered_by_delivery_lead_and_legacy() {
  assert_eq "$(dlr_answered '**[deployer] BLOCKED**' '**[delivery-lead] we wait, not urgent**')" "1" "AC4: delivery-lead free-text reply answers the gate" || return 1
  assert_eq "$(dlr_answered '**[deployer] BLOCKED**' '**[project-manager] we wait, not urgent**')" "1" "AC4: legacy project-manager free-text reply answers" || return 1
  assert_eq "$(dlr_answered '**[deployer] BLOCKED**' '**[jp] looks fine**')" "1" "AC4: jp free-text reply still answers" || return 1
}

# parity: rc_gate_facts output (gate time, answered, gate line 2) is identical for the two spellings
test_dlr_ac4_reconcile_gate_facts_parity_delivery_lead_vs_legacy() {
  local dl pm
  dl=$(dlr_facts '**[deployer] BLOCKED**' $'**[delivery-lead] DECISION**\nResolves: x')
  pm=$(dlr_facts '**[deployer] BLOCKED**' $'**[project-manager] DECISION**\nResolves: x')
  assert_ne "$dl" "" "AC4: rc_gate_facts produced output for the delivery-lead thread" || return 1
  assert_eq "$dl" "$pm" "AC4: rc_gate_facts identical for [delivery-lead] and [project-manager] DECISION" || return 1
}

test_dlr_ac4_reconcile_notes_are_not_answers() {
  assert_eq "$(dlr_answered '**[deployer] BLOCKED**' $'**[delivery-lead] NOTE**\nx')" "0" "AC4: delivery-lead NOTE inert" || return 1
  assert_eq "$(dlr_answered '**[deployer] BLOCKED**' $'**[project-manager] NOTE**\nx')" "0" "AC4: legacy NOTE inert" || return 1
}

test_dlr_ac4_orchestrator_md_names_delivery_lead_and_accepts_legacy() {
  local body; body=$(cat "$ORCH_DLR")
  assert_contains "$body" '[delivery-lead] DECISION' "AC4: orchestrator.md names [delivery-lead] DECISION" || return 1
  assert_contains "$body" '[delivery-lead] JP CONFIRMED' "AC4: orchestrator.md names [delivery-lead] JP CONFIRMED" || return 1
  assert_contains "$body" '\\[(delivery-lead|project-manager)\\]' "AC4: jq regex accepts both spellings" || return 1
  assert_contains "$body" 'legacy' "AC4: project-manager described as legacy" || return 1
  assert_not_contains "$body" 'grep -vF "**[project-manager] "' "AC4: single-pattern grep -vF replaced" || return 1
}

test_dlr_ac4_orchestrator_md_gate_marker_grep_has_two_patterns() {
  local n
  n=$(grep -n 'grep -vF' "$ORCH_DLR" | grep -c 'delivery-lead')
  assert_ne "$n" "0" "AC4: a grep -vF line excludes [delivery-lead]" || return 1
  n=$(grep 'grep -vF' "$ORCH_DLR" | grep 'delivery-lead' | grep -c 'project-manager')
  assert_ne "$n" "0" "AC4: the same grep -vF excludes legacy [project-manager] via a second -e" || return 1
}

test_dlr_ac4_supervisor_and_reconcile_source_name_both_spellings() {
  local f
  for f in "$SUP_DLR" "$RECON_DLR"; do
    assert_contains "$(cat "$f")" 'delivery-lead' "AC4: $(basename "$f") names delivery-lead" || return 1
    assert_contains "$(cat "$f")" 'project-manager' "AC4: $(basename "$f") still names legacy project-manager" || return 1
  done
}

# ------------------------------------------------------------------------------------------ AC6

test_dlr_ac6_no_project_manager_outside_allowlist() {
  local hits
  hits=$(cd "$ROOT_DLR" && git grep -inI "project[- ]manager" -- . \
          ':(exclude)agents/project-manager.md' ':(exclude)skills/orchestrate/tests' ':(exclude)skills/orchestrate/test' \
          ':(exclude)status-page/test' | grep -viE 'legacy|deprecated' || true)
  assert_eq "$hits" "" "AC6: project-manager/project manager outside allowlist:
$hits" || return 1
}

test_dlr_ac6_docs_use_delivery_lead_heading() {
  local f
  for f in CLAUDE.md README.md; do
    grep -q '^\*\*Delivery lead\.\*\*' "$ROOT_DLR/$f" || { fail "AC6: $f lacks a paragraph starting **Delivery lead.**"; return 1; }
    assert_not_contains "$(cat "$ROOT_DLR/$f")" '**Project manager (delivery lead).**' "AC6: $f old heading gone" || return 1
  done
}

test_dlr_ac6_agents_readme_roster_row() {
  local body; body=$(cat "$ROOT_DLR/agents/README.md")
  assert_contains "$body" '| delivery-lead | opus | high |' "AC6: roster row for delivery-lead" || return 1
  assert_contains "$(printf '%s\n' "$body" | grep -i 'project-manager')" 'deprecated' "AC6: a row/note marks project-manager deprecated" || return 1
}

test_dlr_ac6_status_page_readme_uses_delivery_lead() {
  assert_contains "$(cat "$ROOT_DLR/status-page/README.md")" 'delivery lead' "AC6: status-page/README.md says delivery lead" || return 1
}

test_dlr_ac6_readme_cost_ceiling_sentence_names_delivery_lead() {
  assert_contains "$(cat "$ROOT_DLR/README.md")" '[delivery-lead] DECISION' "AC6: README cost-ceiling/delegate text names [delivery-lead] DECISION" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_dlr_'); do run_test "$t"; done
