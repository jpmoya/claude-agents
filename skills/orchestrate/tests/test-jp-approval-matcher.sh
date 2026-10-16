# Issue #310 — ONE shared approval-word matcher. JP writing "approved" (or go/proceed/lgtm/ok to
# proceed, any case) from the issue author's account clears JP's gates; identity (issue author)
# stays the anti-forgery, the exact string no longer is.
#
#   AC1  every positive fixture is returned by jp_go AND accepted by `marker_re jp`; every negative
#        fixture is rejected by both.
#   AC2  a matching word from a non-author login is rejected (same body, only the login differs).
#   AC3  date check unchanged: comment strictly after the stamp.
#   AC4  one word-set definition (hooks/pipeline-markers.sh); jp_go and marker_re jp agree.
#   AC5  existing tests stay green — covered by the scoped run, not a case here.
#   AC6  refusal path logs a validate line with repo, issue and reason (doc-contract on the
#        orchestrator "## Run log" section, same convention as #74's mockup-gate AC6).
#
# Self-contained on purpose (own gh stub + extractor, prefix ja_ / JA_): the runner sources files
# alphabetically, so test-jp-go-lookup.sh's jg_ helpers are not loaded yet. marker_re jp is applied
# to the FULL comment body (AC1 at face value: "body `Looks fine.\napproved`" is a positive).
# Every negative case carries a positive control (a new word, `approved`) so it cannot pass today
# merely because the old exact-`go` rule already rejects the input.

HERE_JA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_JA=$(cd "$HERE_JA/../../.." && pwd)
ORCH_JA="$ROOT_JA/agents/orchestrator.md"
MARKERS_JA="$ROOT_JA/hooks/pipeline-markers.sh"
JA_STAMP="2026-10-16T09:00:00Z"
JA_AFTER="2026-10-16T09:05:00Z"

ja_extract() {
  awk '
    /^```/ { inb = !inb; on = 0; next }
    inb && !on && ($0 ~ /^[[:space:]]*jp_go[[:space:]]*\(\)/ || $0 ~ /^[[:space:]]*function[[:space:]]+jp_go/) { on = 1 }
    inb && on { print; if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit }
  ' "$ORCH_JA"
}

# ja_single <dir> <body> <login> <created_at>
ja_single() {
  jq -n --arg b "$2" --arg u "$3" --arg t "$4" \
    '[{html_url:"https://github.com/o/r/issues/9#issuecomment-77",created_at:$t,user:{login:$u},body:$b}]' > "$1/comments1.json"
  printf '[]\n' > "$1/comments2.json"
  printf '{"user":{"login":"jpmoya"},"author":{"login":"jpmoya"}}\n' > "$1/issue.json"
}

# ja_jpgo <body> [login] [created_at] [stamp] → prints "yes" (jp_go listed it), "no", or "NOHELPER"
ja_jpgo() {
  local body=$1 login=${2:-jpmoya} at=${3:-$JA_AFTER} stamp=${4:-$JA_STAMP} d code out
  code=$(ja_extract)
  [ -n "$code" ] || { echo NOHELPER; return 0; }
  d=$(mktemp -d); ja_single "$d" "$body" "$login" "$at"
  out=$(
    export JA_DIR="$d" ROOT_JA
    gh() {
      local filter="" a prev=""
      for a in "$@"; do
        case "$prev" in --jq|-q|--template) filter=$a ;; esac
        prev=$a
      done
      case "$*" in
        *comments*) if [ -n "$filter" ]; then jq -r "$filter" "$JA_DIR/comments1.json" "$JA_DIR/comments2.json"; else cat "$JA_DIR/comments1.json" "$JA_DIR/comments2.json"; fi ;;
        *"issue view"*|*issues/[0-9]*) if [ -n "$filter" ]; then jq -r "$filter" "$JA_DIR/issue.json"; else cat "$JA_DIR/issue.json"; fi ;;
        *) return 1 ;;
      esac
    }
    export -f gh 2>/dev/null
    . "$ROOT_JA/hooks/pipeline-markers.sh"   # the orchestrator sources the same file for markers()
    eval "$code"
    jp_go 9 "$stamp" 2>/dev/null
  )
  rm -rf "$d"
  case "$out" in *issuecomment-77*) echo yes ;; *) echo no ;; esac
}

# ja_re <body> → true/false: does `marker_re jp` match the full body?
ja_re() {
  ( . "$MARKERS_JA" && jq -n --arg l "$1" --arg re "$(marker_re jp)" '$l | test($re)' )
}

ja_positives() {  # NUL-free list, one fixture per call of ja_each_positive
  printf '%s\0' 'approved' 'Approved.' 'APPROVE' 'go' 'Go!' 'lgtm' 'ok to proceed' 'proceed' \
    '**[jp] GO**' '**[jp] MOCKUPS APPROVED**' $'\n\napproved' $'Looks fine.\napproved' \
    'approved - thanks' 'go, ship it' $'approved \r'
}

ja_negatives() {
  printf '%s\0' 'I will go over this' 'not approved' "don't proceed" 'do not proceed' 'approved?' 'disapproved' 'gone' \
    $'First line here.\nSecond line here.\nwe should go over the rest here\nlast line' \
    'go ahead and change X' 'no go' ''
}

# ---------------------------------------------------------------------------------------- AC1

test_ja_ac1_every_positive_is_returned_by_jp_go() {
  local b
  while IFS= read -r -d '' b; do
    assert_eq "$(ja_jpgo "$b")" "yes" "AC1: jp_go must return positive [$b]" || return 1
  done < <(ja_positives)
}

test_ja_ac1_every_positive_is_accepted_by_marker_re_jp() {
  local b
  while IFS= read -r -d '' b; do
    assert_eq "$(ja_re "$b")" "true" "AC1: marker_re jp must accept positive [$b]" || return 1
  done < <(ja_positives)
}

test_ja_ac1_every_negative_is_rejected_by_jp_go_with_positive_control() {
  local b
  assert_eq "$(ja_jpgo 'approved')" "yes" "AC1: control — plain 'approved' from the author is a go" || return 1
  while IFS= read -r -d '' b; do
    assert_eq "$(ja_jpgo "$b")" "no" "AC1: jp_go must reject negative [$b]" || return 1
  done < <(ja_negatives)
}

test_ja_ac1_every_negative_is_rejected_by_marker_re_jp_with_positive_control() {
  local b
  assert_eq "$(ja_re 'approved')" "true" "AC1: control — marker_re jp accepts 'approved'" || return 1
  while IFS= read -r -d '' b; do
    assert_eq "$(ja_re "$b")" "false" "AC1: marker_re jp must reject negative [$b]" || return 1
  done < <(ja_negatives)
}

# a standalone-line approval is a positive; the same word inside a sentence on that line is not
test_ja_ac1_standalone_line_vs_embedded_word() {
  assert_eq "$(ja_jpgo $'Some context.\nlgtm')" "yes" "AC1: standalone lgtm on line 2" || return 1
  assert_eq "$(ja_jpgo $'Some context.\nplease approved-ish wording here')" "no" "AC1: word embedded in a sentence on line 2" || return 1
}

# ---------------------------------------------------------------------------------------- AC2

test_ja_ac2_same_word_from_non_author_is_rejected() {
  local b
  while IFS= read -r -d '' b; do
    assert_eq "$(ja_jpgo "$b" jpmoya)" "yes" "AC2: control — author [$b] is accepted" || return 1
    assert_eq "$(ja_jpgo "$b" some-bot)" "no" "AC2: identical body from another login must be rejected [$b]" || return 1
  done < <(ja_positives)
}

# ---------------------------------------------------------------------------------------- AC3

test_ja_ac3_comment_strictly_after_the_stamp() {
  assert_eq "$(ja_jpgo approved jpmoya "2026-10-16T09:00:01Z")" "yes" "AC3: +1s is accepted" || return 1
  assert_eq "$(ja_jpgo approved jpmoya "$JA_STAMP")" "no" "AC3: exactly at the stamp is rejected" || return 1
  assert_eq "$(ja_jpgo approved jpmoya "2026-10-16T08:59:59Z")" "no" "AC3: -1s is rejected" || return 1
}

# ---------------------------------------------------------------------------------------- AC4

test_ja_ac4_a_matcher_function_exists_in_hooks() {
  ( . "$MARKERS_JA"; type is_jp_approval >/dev/null 2>&1 || type jp_approval_re >/dev/null 2>&1 ) \
    || { fail "AC4: hooks/pipeline-markers.sh must define is_jp_approval or jp_approval_re"; return 1; }
}

# one list: the phrase set is written once in hooks/pipeline-markers.sh
test_ja_ac4_word_set_defined_once_in_hooks() {
  local n
  n=$(grep -c 'ok to proceed' "$MARKERS_JA")
  assert_eq "$n" "1" "AC4: 'ok to proceed' appears exactly once in hooks/pipeline-markers.sh" || return 1
  n=$(grep -c 'lgtm' "$MARKERS_JA")
  assert_eq "$n" "1" "AC4: 'lgtm' appears exactly once in hooks/pipeline-markers.sh" || return 1
}

# agreement: hooks matcher and the orchestrator's jp_go accept/reject the same probes (author, after stamp)
test_ja_ac4_hooks_and_orchestrator_agree() {
  local b a r
  assert_eq "$(ja_re 'proceed')" "true" "AC4: control — hooks accepts 'proceed'" || return 1
  for b in 'approved' 'approve' 'go' 'proceed' 'lgtm' 'ok to proceed' 'PROCEED' 'Lgtm.' 'Ok To Proceed!' \
           '**[jp] GO**' '**[jp] MOCKUPS APPROVED**' 'ok to' 'proceeded' 'approvals' 'lgtm thanks' 'go - ship' \
           $'x\nproceed' $'proceed to merge this' 'go ahead' 'not lgtm' 'gone'; do
    a=$(ja_jpgo "$b"); r=$(ja_re "$b")
    case "$a:$r" in yes:true|no:false) ;; *) fail "AC4: jp_go=$a but marker_re jp=$r for [$b]"; return 1 ;; esac
  done
}

# ---------------------------------------------------------------------------------------- AC6

ja_section() {  # ja_section <file> <heading> — lines under the heading up to the next heading of same/higher level
  awk -v h="$2" '
    BEGIN { n = match(h, /[^#]/) - 1 }
    /^```/ { if (on) print; fence = !fence; next }
    !fence && index($0, h) == 1 { on = 1; next }
    on && !fence && match($0, /^#+ /) && (RLENGTH - 1) <= n { exit }
    on { print }' "$1"
}

test_ja_ac6_run_log_documents_refusal_validate_line() {
  local log line
  log=$(ja_section "$ORCH_JA" '## Run log')
  assert_ne "$log" "" "AC6: Run log section exists" || return 1
  line=$(printf '%s\n' "$log" | grep -E '"event":"validate"' | grep -E '"stage":"jp[-_](go|approval)"' | grep -F '"result":"fail"')
  assert_ne "$line" "" "AC6: Run log needs a failing validate line for the JP approval check (stage jp-go or jp-approval)" || return 1
  for k in '"repo"' '"issue"' '"reason"'; do
    assert_contains "$line" "$k" "AC6: refusal validate line carries $k" || return 1
  done
}

test_ja_ac6_refusal_line_logs_no_comment_body() {
  local log line
  log=$(ja_section "$ORCH_JA" '## Run log')
  line=$(printf '%s\n' "$log" | grep -E '"stage":"jp[-_](go|approval)"')
  assert_ne "$line" "" "AC6: approval validate lines exist" || return 1
  assert_not_contains "$line" '"body"' "AC6: no comment body field in the log line" || return 1
}

run_test test_ja_ac1_every_positive_is_returned_by_jp_go
run_test test_ja_ac1_every_positive_is_accepted_by_marker_re_jp
run_test test_ja_ac1_every_negative_is_rejected_by_jp_go_with_positive_control
run_test test_ja_ac1_every_negative_is_rejected_by_marker_re_jp_with_positive_control
run_test test_ja_ac1_standalone_line_vs_embedded_word
run_test test_ja_ac2_same_word_from_non_author_is_rejected
run_test test_ja_ac3_comment_strictly_after_the_stamp
run_test test_ja_ac4_a_matcher_function_exists_in_hooks
run_test test_ja_ac4_word_set_defined_once_in_hooks
run_test test_ja_ac4_hooks_and_orchestrator_agree
run_test test_ja_ac6_run_log_documents_refusal_validate_line
run_test test_ja_ac6_refusal_line_logs_no_comment_body
