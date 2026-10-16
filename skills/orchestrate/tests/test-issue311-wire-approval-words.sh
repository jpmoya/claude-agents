# Issue #311 — wire the shared approval words (#310) into EVERY JP gate and its docs, so a
# 1478-style refusal ("approved" on a MOCKUPS PENDING APPROVAL ticket) cannot recur.
#
#   AC1  each gate (mockup approval, infra AWAITING GO, JP-only-list BLOCKED resume, infra BLOCKED
#        go) passes on a set word and refuses on every negative. Behavioural fixtures drive jp_go
#        (the ONE command every gate row must use); doc-contract cases pin that each gate row
#        names it and no longer demands a single string.
#   AC2  grep of agents/ and hooks/ finds no text stating "first line exactly `go`" / "exactly
#        `**[jp] MOCKUPS APPROVED**`" as the sole accepted form.
#   AC3  the 1478 reproduction: test_aw_1478_*  (named in the PR).
#   AC4  existing suites green — not a case here (scoped run).
#   AC5  refusal/pass paths log a validate line naming the form checked ("approval word matched"),
#        never the author (doc-contract on the orchestrator "## Run log", #74/#310 convention).
#
# NOT widened: [delivery-lead] DECISION / JP CONFIRMED never act as a go or an approval. Every agent
# comment is posted from the SAME GitHub account as JP, so the matcher alone cannot tell them apart:
# jp_go must also refuse a comment whose first line is an agent stage marker `**[<agent>] ...**`
# (anything but `**[jp] ...**`), even when a later line is a bare `approved`.
#
# "approved for <file>" (protected-workflow approval): grep of agents/ hooks/ skills/orchestrate
# finds NO consumer of that phrase on this base, so there is nothing to wire; the AC2 grep case
# below keeps it that way.
#
# Self-contained (own gh stub + extractor, prefix aw_ / AW_); doc cases read tracked files only.

HERE_AW=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_AW=$(cd "$HERE_AW/../../.." && pwd)
ORCH_AW="$ROOT_AW/agents/orchestrator.md"
INFRA_AW="$ROOT_AW/agents/infra-operator.md"
UX_AW="$ROOT_AW/agents/ui-ux-designer.md"
MARKERS_AW="$ROOT_AW/hooks/pipeline-markers.sh"
AW_PENDING="2026-10-16T09:00:00Z"   # created_at of the MOCKUPS PENDING APPROVAL / AWAITING GO / BLOCKED comment
AW_AFTER="2026-10-16T09:05:00Z"
AW_BEFORE="2026-10-16T08:55:00Z"

aw_extract() {
  awk '
    /^```/ { inb = !inb; on = 0; next }
    inb && !on && ($0 ~ /^[[:space:]]*jp_go[[:space:]]*\(\)/) { on = 1 }
    inb && on { print; if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit }
  ' "$ORCH_AW"
}

aw_gh() {
  local filter="" a prev=""
  for a in "$@"; do
    case "$prev" in --jq|-q|--template) filter=$a ;; esac
    prev=$a
  done
  case "$*" in
    *comments*) if [ -n "$filter" ]; then jq -r "$filter" "$AW_DIR/comments1.json" "$AW_DIR/comments2.json"; else cat "$AW_DIR/comments1.json" "$AW_DIR/comments2.json"; fi ;;
    *"issue view"*|*issues/[0-9]*) if [ -n "$filter" ]; then jq -r "$filter" "$AW_DIR/issue.json"; else cat "$AW_DIR/issue.json"; fi ;;
    *) return 1 ;;
  esac
}

# aw_jpgo <body> [login] [created_at] [stamp] → yes | no | NOHELPER
aw_jpgo() {
  local body=$1 login=${2:-jpmoya} at=${3:-$AW_AFTER} stamp=${4:-$AW_PENDING} d code out
  code=$(aw_extract)
  [ -n "$code" ] || { echo NOHELPER; return 0; }
  d=$(mktemp -d)
  jq -n --arg b "$body" --arg u "$login" --arg t "$at" \
    '[{html_url:"https://github.com/o/r/issues/9#issuecomment-77",created_at:$t,user:{login:$u},body:$b}]' > "$d/comments1.json"
  printf '[]\n' > "$d/comments2.json"
  printf '{"user":{"login":"jpmoya"},"author":{"login":"jpmoya"}}\n' > "$d/issue.json"
  out=$(
    export AW_DIR="$d" ROOT_AW
    gh() { aw_gh "$@"; }
    export -f aw_gh gh 2>/dev/null
    . "$ROOT_AW/hooks/pipeline-markers.sh"
    eval "$code"
    jp_go 9 "$stamp" 2>/dev/null
  )
  rm -rf "$d"
  case "$out" in *issuecomment-77*) echo yes ;; *) echo no ;; esac
}

aw_has()  { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
aw_lacks() { if grep -qF -- "$2" "$1"; then fail "$(basename "$1"): must no longer contain [$2]"; return 1; fi; }
# aw_row <file> <fixed line prefix> → the one line starting with that prefix
aw_row() { grep -F -- "$2" "$1" | grep -F -- "$3" | head -1; }

# ------------------------------------------------------------------------- AC1: behaviour fixtures

# Gate fixture set: the same comment is tried against a stamp (MOCKUPS PENDING APPROVAL, AWAITING GO,
# a BLOCKED — the lookup is identical, it is always jp_go <N> <stamp>).
test_aw_ac1_set_words_clear_every_gate() {
  local b
  for b in 'approved' 'Approved, proceed' 'go' 'lgtm' 'proceed' 'ok to proceed' $'Looks fine.\napproved' '**[jp] GO**' '**[jp] MOCKUPS APPROVED**'; do
    assert_eq "$(aw_jpgo "$b")" "yes" "AC1: author [$b] after the stamp clears the gate" || return 1
  done
}

test_aw_ac1_non_author_never_clears_a_gate() {
  assert_eq "$(aw_jpgo 'approved')" "yes" "AC1: control — author" || return 1
  assert_eq "$(aw_jpgo 'approved' some-bot)" "no" "AC1: same text from a non-author" || return 1
  assert_eq "$(aw_jpgo 'Approved, proceed' some-bot)" "no" "AC1: Approved, proceed from a non-author" || return 1
}

test_aw_ac1_approval_dated_before_the_stamp_does_nothing() {
  assert_eq "$(aw_jpgo 'approved')" "yes" "AC1: control — after the stamp" || return 1
  assert_eq "$(aw_jpgo 'approved' jpmoya "$AW_BEFORE")" "no" "AC1: approved before MOCKUPS PENDING APPROVAL" || return 1
  assert_eq "$(aw_jpgo 'approved' jpmoya "$AW_PENDING")" "no" "AC1: approved AT the stamp" || return 1
}

test_aw_ac1_not_approved_yet_is_not_an_approval() {
  assert_eq "$(aw_jpgo 'approved')" "yes" "AC1: control" || return 1
  assert_eq "$(aw_jpgo 'not approved yet')" "no" "AC1: 'not approved yet' is revision feedback, not approval" || return 1
  assert_eq "$(aw_jpgo $'Please change the header.\nnot approved yet')" "no" "AC1: later-line 'not approved yet'" || return 1
}

# NOT widened: a delegate's comment is posted from JP's own account, so its approval-looking body
# must not count. Only a first line `**[jp] ...**` or plain prose can be JP's.
test_aw_ac1_delegate_markers_never_act_as_a_go_or_approval() {
  local b
  assert_eq "$(aw_jpgo 'approved')" "yes" "control" || return 1
  for b in $'**[delivery-lead] JP CONFIRMED**\nResolves: https://github.com/o/r/issues/9#issuecomment-1\napproved' \
           $'**[delivery-lead] DECISION**\nResolves: https://github.com/o/r/issues/9#issuecomment-1\ngo' \
           $'**[project-manager] JP CONFIRMED**\nResolves: https://github.com/o/r/issues/9#issuecomment-1\nlgtm' \
           $'**[test-writer] NOTE**\nproceed'; do
    assert_eq "$(aw_jpgo "$b")" "no" "AC1: agent-marker comment must not clear AWAITING GO / mockups [${b%%$'\n'*}]" || return 1
  done
}

# ---------------------------------------------------------------------------- AC1/AC3: 1478 repro

# 1478: `MOCKUPS PENDING APPROVAL`, then the issue author comments `approved` → the gate passes.
# The gate row and the gate section must send the orchestrator to jp_go (the one definition),
# not to a hand-compared exact first line.
test_aw_1478_mockups_pending_then_approved_passes() {
  local row sec
  assert_eq "$(aw_jpgo 'approved')" "yes" "1478: author 'approved' after MOCKUPS PENDING APPROVAL is found by jp_go" || return 1
  row=$(aw_row "$ORCH_AW" '`[ui-ux-designer] MOCKUPS PENDING APPROVAL` + JP approval' 'Proceed to next stage')
  [ -n "$row" ] || { fail "1478: mockup approval routing row not found"; return 1; }
  case "$row" in *'jp_go'*) ;; *) fail "1478: routing row must resolve approval with jp_go"; return 1 ;; esac
  case "$row" in *'first line exactly'*|*'a sentence containing "approved" is not an approval'*) fail "1478: row still demands an exact first line / calls 'approved' a non-approval"; return 1 ;; esac
  sec=$(grep -F '1. **JP approves**' "$ORCH_AW" | head -1)
  [ -n "$sec" ] || { fail "1478: '1. **JP approves**' gate item not found"; return 1; }
  case "$sec" in *'jp_go'*) ;; *) fail "1478: gate item must use jp_go"; return 1 ;; esac
  case "$sec" in *'must be exactly'*|*'no other wording counts'*) fail "1478: gate item still says only the exact marker counts"; return 1 ;; esac
  case "$sec" in *'approved'*) ;; *) fail "1478: gate item must name the accepted words"; return 1 ;; esac
}

test_aw_1478_awaiting_go_then_approved_proceed_passes() {
  local row
  assert_eq "$(aw_jpgo 'Approved, proceed')" "yes" "AWAITING GO + 'Approved, proceed' (author) clears it" || return 1
  row=$(aw_row "$ORCH_AW" '`[infra-operator] AWAITING GO` + JP go comment' 'Re-dispatch')
  case "$row" in *'jp_go'*) ;; *) fail "AWAITING GO row must use jp_go"; return 1 ;; esac
}

# ------------------------------------------- revision feedback never swallows a matching approval

test_aw_revision_rows_treat_a_matching_approval_as_approval() {
  local r1 r2
  r1=$(aw_row "$ORCH_AW" '| JP revision feedback' 'Re-dispatch ui-ux-designer')
  r2=$(grep -F '2. **JP requests revisions**' "$ORCH_AW" | head -1)
  [ -n "$r1" ] && [ -n "$r2" ] || { fail "revision-feedback row or gate item not found"; return 1; }
  case "$r1" in *'NOT the exact `**[jp] MOCKUPS APPROVED**`'*) fail "revision row still keys on the exact marker"; return 1 ;; esac
  case "$r2" in *'neither the exact approval marker'*) fail "revision item still keys on the exact marker"; return 1 ;; esac
  case "$r1" in *'jp_go'*|*'approval word'*|*'approval phrase'*) ;; *) fail "revision row must exclude a matching approval (jp_go / approval word)"; return 1 ;; esac
  case "$r2" in *'jp_go'*|*'approval word'*|*'approval phrase'*) ;; *) fail "revision item must exclude a matching approval (jp_go / approval word)"; return 1 ;; esac
  case "$r1$r2" in *'never'*) ;; *) fail "rows must say a matching approval is never revision feedback"; return 1 ;; esac
}

# ---------------------------------------------------------------- AC1: the other gates, doc-contract

test_aw_jp_only_blocked_resume_accepts_the_approval_set() {
  local row
  row=$(aw_row "$ORCH_AW" 'code-track `BLOCKED` + a later `[delivery-lead] DECISION`' 'JP-only-list')
  [ -n "$row" ] || { fail "delegated-decision row not found"; return 1; }
  case "$row" in *'exact-form go'*|*'in that exact form'*) fail "JP-only BLOCKED resume still demands an exact-form go"; return 1 ;; esac
  case "$row" in *'jp_go'*) ;; *) fail "JP-only BLOCKED resume must use jp_go"; return 1 ;; esac
}

test_aw_delegate_authority_not_widened() {
  local row
  row=$(aw_row "$ORCH_AW" 'code-track `BLOCKED` + a later `[delivery-lead] DECISION`' 'JP-only-list')
  case "$row" in *'never a `go` or a mockup approval'*) ;; *) fail "row 86 must still say JP CONFIRMED is never a go or a mockup approval"; return 1 ;; esac
  case "$row" in *'still never clears a JP-only-list `BLOCKED`'*) ;; *) fail "row 86 must still say a delegate never clears a JP-only BLOCKED"; return 1 ;; esac
  aw_has "$ORCH_AW" 'A `[delivery-lead]` marker never clears a prod infra `BLOCKED`' || return 1
}

test_aw_infra_blocked_go_rows_drop_the_exact_first_line() {
  local r
  r=$(grep -F 'infra-planner / infra-operator (resume on JP go after `BLOCKED`)' "$ORCH_AW" | head -1)
  [ -n "$r" ] || { fail "infra BLOCKED go pre-dispatch row not found"; return 1; }
  case "$r" in *'first-line exact'*) fail "infra BLOCKED go row still says first-line exact"; return 1 ;; esac
  case "$r" in *'jp_go'*) ;; *) fail "infra BLOCKED go row must use jp_go"; return 1 ;; esac
}

test_aw_infra_operator_go_definition_and_awaiting_go_wording() {
  local def
  def=$(grep -F "JP's go:" "$INFRA_AW" | head -1)
  [ -n "$def" ] || { fail "infra-operator.md go definition not found"; return 1; }
  case "$def" in *'first line is exactly'*) fail "go definition still demands first line exactly go"; return 1 ;; esac
  case "$def" in *'approved'*'proceed'*'lgtm'*|*'jp_go'*|*'jp_approval_re'*) ;; *) fail "go definition must name the approval words (or the shared matcher)"; return 1 ;; esac
  aw_has "$INFRA_AW" 'Reply `go` (or approved / proceed / lgtm) on this issue to run the remaining prod steps.' || return 1
  aw_lacks "$INFRA_AW" 'Reply `go` on this issue to run the remaining prod steps.' || return 1
  aw_lacks "$INFRA_AW" 'first line, exact' || return 1
  case "$(grep -F 'Gate.' "$INFRA_AW" | head -1)" in *'exact text JP should reply: `go`'*) fail "Gate step still demands the one string go"; return 1 ;; esac
}

test_aw_mockup_review_request_names_the_accepted_words() {
  local line
  line=$(grep -F 'please review these mockups' "$UX_AW" | head -1)
  [ -n "$line" ] || { fail "review-request line not found in ui-ux-designer.md"; return 1; }
  case "$line" in *'reply with exactly'*) fail "review request still demands one exact string"; return 1 ;; esac
  case "$line" in *'approved'*) ;; *) fail "review request must tell JP that approved works"; return 1 ;; esac
}

# ---------------------------------------------------------------------------------------- AC2

test_aw_ac2_no_sole_exact_form_text_left_in_agents_and_hooks() {
  local hits
  hits=$(grep -rnE -i \
    -e 'first line (is |must be )?exactly `?go' \
    -e 'first line is exactly `\*\*\[jp\]' \
    -e 'exactly `\*\*\[jp\] (MOCKUPS APPROVED|GO)\*\*`' \
    -e 'exact `\*\*\[jp\] MOCKUPS APPROVED\*\*`' \
    -e 'whose first line is exactly `go`' \
    -e 'first line, exact' -e 'first-line exact' -e 'exact-form go' -e 'in that exact form' \
    -e 'no other wording counts' -e 'reply with exactly' -e 'exact text JP should reply' \
    "$ROOT_AW/agents" "$ROOT_AW/hooks" 2>/dev/null | cut -c1-160)
  assert_eq "$hits" "" "AC2: sole-accepted-form wording still present" || return 1
}

test_aw_ac2_no_approved_for_file_consumer_bypasses_the_matcher() {
  # no consumer of the "approved for <file>" phrase exists on this base; if one appears it must be wired here
  local hits
  hits=$(grep -rniE 'approved for' "$ROOT_AW/agents" "$ROOT_AW/hooks" "$ROOT_AW/skills/orchestrate" --exclude-dir=tests 2>/dev/null | cut -c1-160)
  assert_eq "$hits" "" "an 'approved for <file>' consumer exists: wire it to the shared matcher and add a case" || return 1
}

# ---------------------------------------------------------------------------------------- AC5

test_aw_ac5_gate_log_lines_name_the_form_checked_not_the_author() {
  local lines pass fail_l
  lines=$(grep -F '"stage":"mockup-gate"' "$ORCH_AW")
  pass=$(printf '%s\n' "$lines" | grep -F '"result":"pass"' | head -1)
  fail_l=$(printf '%s\n' "$lines" | grep -F '"result":"fail"' | head -1)
  [ -n "$pass" ] && [ -n "$fail_l" ] || { fail "mockup-gate pass+fail log examples missing in Run log"; return 1; }
  case "$pass" in *'approval word matched'*) ;; *) fail "mockup-gate pass reason must be 'approval word matched'"; return 1 ;; esac
  case "$fail_l" in *'approval word'*) ;; *) fail "mockup-gate fail reason must name the approval-word form"; return 1 ;; esac
  case "$pass$fail_l" in *'not exactly'*|*'jpmoya'*) fail "mockup-gate log reasons must not say 'exactly' or name the author"; return 1 ;; esac
  # the prose at the gate agrees
  grep -F 'Log the outcome (pass on approval' "$ORCH_AW" | grep -qF 'approval word matched' || { fail "gate prose must give 'approval word matched' as the pass reason"; return 1; }
}

test_aw_ac5_jp_go_refusal_line_documented_with_repo_issue_reason() {
  local l
  l=$(grep -F '"event":"validate"' "$ORCH_AW" | grep -E '"stage":"(jp-go|jp-approval)"' | grep -F '"result":"fail"' | head -1)
  [ -n "$l" ] || { fail "jp-go/jp-approval fail log line missing"; return 1; }
  case "$l" in *'"repo"'*'"issue"'*'"reason"'*) ;; *) fail "jp-go fail line must carry repo, issue, reason"; return 1 ;; esac
}

run_test test_aw_ac1_set_words_clear_every_gate
run_test test_aw_ac1_non_author_never_clears_a_gate
run_test test_aw_ac1_approval_dated_before_the_stamp_does_nothing
run_test test_aw_ac1_not_approved_yet_is_not_an_approval
run_test test_aw_ac1_delegate_markers_never_act_as_a_go_or_approval
run_test test_aw_1478_mockups_pending_then_approved_passes
run_test test_aw_1478_awaiting_go_then_approved_proceed_passes
run_test test_aw_revision_rows_treat_a_matching_approval_as_approval
run_test test_aw_jp_only_blocked_resume_accepts_the_approval_set
run_test test_aw_delegate_authority_not_widened
run_test test_aw_infra_blocked_go_rows_drop_the_exact_first_line
run_test test_aw_infra_operator_go_definition_and_awaiting_go_wording
run_test test_aw_mockup_review_request_names_the_accepted_words
run_test test_aw_ac2_no_sole_exact_form_text_left_in_agents_and_hooks
run_test test_aw_ac2_no_approved_for_file_consumer_bypasses_the_matcher
run_test test_aw_ac5_gate_log_lines_name_the_form_checked_not_the_author
run_test test_aw_ac5_jp_go_refusal_line_documented_with_repo_issue_reason
