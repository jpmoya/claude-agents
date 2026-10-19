# Issue #303 — one canonical `jp_go <N> <blocked_created_at>` helper in agents/orchestrator.md so a
# run never hand-writes a go search that misses JP's go (Benjis-Plants/benjis-quoting-tool#747).
#
#   AC1  helper `jp_go` sits next to `markers()`; prints URL + created_at of every comment by the
#        issue author, created strictly after <blocked_created_at>, whose first line (trailing
#        whitespace trimmed) is exactly `go`, `GO` or `**[jp] GO**`. Failed read: empty stdout,
#        non-zero return.
#   AC2  the four resume rows + validation rows call jp_go; the exact form is spelled out once.
#   AC3  "no go exists" claims are allowed only after jp_go ran and printed nothing.
#   AC4  hooks/pipeline-markers.sh and skills/orchestrate/supervisor.sh unchanged.
#   AC5  behavioural: helper extracted from orchestrator.md, run against a fixture with `gh` stubbed.
#   AC6  post-deploy observation (runs.jsonl) — not testable here.
#
# `gh` is stubbed as a shell function: it serves the fixture JSON for the comments endpoint and the
# issue-author lookup (via `gh api .../issues/N`, or `gh issue view N --json author|user`), and
# applies any --jq/-q filter with real jq, so the helper's own filter is what is under test.
# Helpers/vars prefixed jg_ / JG_ (all test files share one shell).

HERE_JG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_JG=$(cd "$HERE_JG/../../.." && pwd)
ORCH_JG="$ROOT_JG/agents/orchestrator.md"

JG_BLOCKED_AT="2026-10-15T16:40:00Z"

# jg_extract — print the jp_go function definition from a fenced block of orchestrator.md: from the
# `jp_go() {` line to the first line that is exactly `}` (empty if none). The surrounding doc block
# holds pseudo-calls such as `markers <N>`, so only the function itself is evaluated.
jg_extract() {
  awk '
    /^```/ { inb = !inb; on = 0; next }
    inb && !on && ($0 ~ /^[[:space:]]*jp_go[[:space:]]*\(\)/ || $0 ~ /^[[:space:]]*function[[:space:]]+jp_go/) { on = 1 }
    inb && on { print; if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit }
  ' "$ORCH_JG"
}

# jg_fixture <dir> — writes comments page(s) + issue object. BLOCKED, then go, then supervisor NOTE.
jg_fixture() {
  local d=$1
  cat > "$d/comments1.json" <<'JSON'
[
 {"html_url":"https://github.com/o/r/issues/9#issuecomment-1","created_at":"2026-10-15T16:40:00Z","user":{"login":"jpmoya"},"body":"**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp — private doc"},
 {"html_url":"https://github.com/o/r/issues/9#issuecomment-2","created_at":"2026-10-15T16:48:39Z","user":{"login":"jpmoya"},"body":"go"},
 {"html_url":"https://github.com/o/r/issues/9#issuecomment-3","created_at":"2026-10-15T16:48:42Z","user":{"login":"jpmoya"},"body":"**[supervisor] NOTE** claim: host 2026-10-15T16:48:42Z"}
]
JSON
  printf '[]\n' > "$d/comments2.json"
  printf '{"user":{"login":"jpmoya"},"author":{"login":"jpmoya"}}\n' > "$d/issue.json"
}

# jg_comments_json <dir> <body> <login> <created_at> — single-comment fixture, replaces comments1/2
jg_single() {
  local d=$1
  jq -n --arg b "$2" --arg u "$3" --arg t "$4" \
    '[{html_url:"https://github.com/o/r/issues/9#issuecomment-77",created_at:$t,user:{login:$u},body:$b}]' > "$d/comments1.json"
  printf '[]\n' > "$d/comments2.json"
}

# jg_run <dir> <mode> [blocked_at] — runs the extracted helper with a stubbed gh. Prints
# "<stdout>" then "RC=<n>" on a final line. mode: ok | fail_all | fail_comments | fail_author
jg_run() {
  local d=$1 mode=$2 at=${3:-$JG_BLOCKED_AT} code
  code=$(jg_extract)
  [ -n "$code" ] || { printf 'NOHELPER\nRC=99\n'; return 0; }
  (
    export JG_DIR="$d" JG_MODE="$mode"
    gh() {
      local filter="" a path="" prev="" kind=""
      for a in "$@"; do
        case "$prev" in --jq|-q|--template) filter=$a ;; esac
        case "$a" in
          repos/*|/repos/*) path=$a ;;
        esac
        prev=$a
      done
      case "$JG_MODE" in fail_all) return 1 ;; esac
      case "$*" in
        *comments*) [ "$JG_MODE" = fail_comments ] && return 1; kind=comments ;;
        *"issue view"*|*issues/[0-9]*) [ "$JG_MODE" = fail_author ] && return 1; kind=issue ;;
        *) return 1 ;;
      esac
      if [ "$kind" = comments ]; then
        if [ -n "$filter" ]; then jq -r "$filter" "$JG_DIR/comments1.json" "$JG_DIR/comments2.json"
        else cat "$JG_DIR/comments1.json" "$JG_DIR/comments2.json"; fi
      else
        if [ -n "$filter" ]; then jq -r "$filter" "$JG_DIR/issue.json"; else cat "$JG_DIR/issue.json"; fi
      fi
    }
    export -f gh 2>/dev/null
    . "$ROOT_JG/hooks/pipeline-markers.sh"   # jp_go uses jp_approval_re (#310), sourced by the orchestrator like markers()
    eval "$code"
    out=$(jp_go 9 "$at" 2>/dev/null); rc=$?
    printf '%s\nRC=%s\n' "$out" "$rc"
  )
}

jg_out() { printf '%s\n' "$1" | sed '$d'; }
jg_rc() { printf '%s\n' "$1" | tail -1 | sed 's/^RC=//'; }

# ---------------------------------------------------------------------------------------- AC1

test_jg_ac1_helper_defined_once_next_to_markers() {
  local n m j
  n=$(grep -cE '^[[:space:]]*(function[[:space:]]+)?jp_go[[:space:]]*\(\)' "$ORCH_JG")
  assert_eq "$n" "1" "AC1: exactly one jp_go() definition in orchestrator.md" || return 1
  m=$(grep -n '^markers()' "$ORCH_JG" | head -1 | cut -d: -f1)
  j=$(grep -nE '^[[:space:]]*(function[[:space:]]+)?jp_go[[:space:]]*\(\)' "$ORCH_JG" | head -1 | cut -d: -f1)
  [ -n "$m" ] && [ -n "$j" ] || { fail "AC1: markers()/jp_go() lines not both found"; return 1; }
  [ "$j" -gt "$m" ] && [ $((j - m)) -le 20 ] || { fail "AC1: jp_go (line $j) must be within 20 lines after markers() (line $m)"; return 1; }
}

test_jg_ac1_returns_the_go_and_prints_url_and_timestamp() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  r=$(jg_run "$d" ok)
  assert_eq "$(jg_rc "$r")" "0" "AC1: rc 0" || return 1
  assert_contains "$(jg_out "$r")" "https://github.com/o/r/issues/9#issuecomment-2" "AC1: go URL printed" || return 1
  assert_contains "$(jg_out "$r")" "2026-10-15T16:48:39Z" "AC1: go timestamp printed" || return 1
  assert_not_contains "$(jg_out "$r")" "issuecomment-3" "AC1: supervisor NOTE is not a go" || return 1
  assert_not_contains "$(jg_out "$r")" "issuecomment-1" "AC1: the BLOCKED itself is not a go" || return 1
  rm -rf "$d"
}

test_jg_ac1_accepted_forms() {
  local d r body
  d=$(mktemp -d); jg_fixture "$d"
  for body in 'go' 'GO' '**[jp] GO**' 'go   ' $'go\t' $'go\nplease use the revised PDF' $'**[jp] GO**\nrest'; do
    jg_single "$d" "$body" jpmoya 2026-10-15T16:50:00Z
    r=$(jg_run "$d" ok)
    assert_contains "$(jg_out "$r")" "issuecomment-77" "AC1: accepted form [$body]" || { rm -rf "$d"; return 1; }
    assert_eq "$(jg_rc "$r")" "0" "AC1: rc 0 for [$body]" || { rm -rf "$d"; return 1; }
  done
  rm -rf "$d"
}

test_jg_ac1_rejected_forms() {
  local d r body
  d=$(mktemp -d); jg_fixture "$d"
  for body in 'go ahead' '**JP: go**' 'going' 'ok go' 'no go' '**[jp] GO** now' '**[delivery-lead] DECISION**' ''; do
    jg_single "$d" "$body" jpmoya 2026-10-15T16:50:00Z
    r=$(jg_run "$d" ok)
    assert_eq "$(jg_out "$r")" "" "AC1: rejected form [$body] prints nothing" || { rm -rf "$d"; return 1; }
    assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || { rm -rf "$d"; return 1; }
  done
  rm -rf "$d"
}

test_jg_ac1_go_from_non_author_ignored() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jg_single "$d" 'go' someone-else 2026-10-15T16:50:00Z
  r=$(jg_run "$d" ok)
  assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || return 1
  assert_eq "$(jg_out "$r")" "" "AC1: non-author go prints nothing" || return 1
  rm -rf "$d"
}

test_jg_ac1_go_dated_before_blocked_ignored() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jg_single "$d" 'go' jpmoya 2026-10-15T16:39:59Z
  r=$(jg_run "$d" ok)
  assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || return 1
  assert_eq "$(jg_out "$r")" "" "AC1: go before BLOCKED prints nothing" || return 1
  rm -rf "$d"
}

# boundary: created_at > blocked_created_at is strict (spec Decisions)
test_jg_ac1_go_at_exact_blocked_timestamp_ignored_and_one_second_later_accepted() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jg_single "$d" 'go' jpmoya "$JG_BLOCKED_AT"
  r=$(jg_run "$d" ok)
  assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || return 1
  assert_eq "$(jg_out "$r")" "" "AC1: go at the same second prints nothing" || return 1
  jg_single "$d" 'go' jpmoya 2026-10-15T16:40:01Z
  r=$(jg_run "$d" ok)
  assert_contains "$(jg_out "$r")" "issuecomment-77" "AC1: go one second later is returned" || return 1
  rm -rf "$d"
}

test_jg_ac1_prints_every_qualifying_go() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jq -n '[
    {html_url:"u-a",created_at:"2026-10-15T16:50:00Z",user:{login:"jpmoya"},body:"go"},
    {html_url:"u-b",created_at:"2026-10-15T16:51:00Z",user:{login:"jpmoya"},body:"**[jp] GO**"}]' > "$d/comments1.json"
  r=$(jg_run "$d" ok)
  assert_contains "$(jg_out "$r")" "u-a" "AC1: first go" || return 1
  assert_contains "$(jg_out "$r")" "u-b" "AC1: second go" || return 1
  rm -rf "$d"
}

# --paginate emits one array per page; a go on page 2 must be found
test_jg_ac1_go_on_second_page_found() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jq -n '[{html_url:"u-p1",created_at:"2026-10-15T16:41:00Z",user:{login:"jpmoya"},body:"hello"}]' > "$d/comments1.json"
  jq -n '[{html_url:"u-p2",created_at:"2026-10-15T16:55:00Z",user:{login:"jpmoya"},body:"go"}]' > "$d/comments2.json"
  r=$(jg_run "$d" ok)
  assert_contains "$(jg_out "$r")" "u-p2" "AC1: page-2 go found" || return 1
  rm -rf "$d"
}

test_jg_ac1_failed_read_prints_nothing_and_returns_nonzero() {
  local d r mode
  d=$(mktemp -d); jg_fixture "$d"
  for mode in fail_all fail_comments fail_author; do
    r=$(jg_run "$d" "$mode")
    assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || { rm -rf "$d"; return 1; }
    assert_eq "$(jg_out "$r")" "" "AC1: [$mode] stdout empty" || { rm -rf "$d"; return 1; }
    assert_ne "$(jg_rc "$r")" "0" "AC1: [$mode] returns non-zero" || { rm -rf "$d"; return 1; }
  done
  rm -rf "$d"
}

# a clean read with no go must not look like a failed read
test_jg_ac1_no_go_on_clean_read_is_distinguishable_from_failure() {
  local d r
  d=$(mktemp -d); jg_fixture "$d"
  jg_single "$d" 'go ahead' jpmoya 2026-10-15T16:50:00Z
  r=$(jg_run "$d" ok)
  assert_ne "$(jg_out "$r")" "NOHELPER" "AC1: helper exists" || return 1
  assert_eq "$(jg_rc "$r")" "0" "AC1: clean read with no go returns 0 (non-zero is reserved for failed reads)" || return 1
  rm -rf "$d"
}

# ---------------------------------------------------------------------------------------- AC2

# jg_line <fixed-needle> — the single orchestrator.md line containing it ('' unless exactly one)
jg_line() {
  [ "$(grep -cF -- "$1" "$ORCH_JG")" = "1" ] || { printf ''; return 1; }
  grep -F -- "$1" "$ORCH_JG"
}

jg_row_uses_helper() {  # <label> <needle>
  local row
  row=$(jg_line "$2")
  assert_ne "$row" "" "AC2: $1 row found (exactly one)" || return 1
  assert_contains "$row" 'jp_go' "AC2: $1 row calls jp_go" || return 1
}

test_jg_ac2_code_track_carveout_row_uses_helper() { jg_row_uses_helper "code-track JP-only carve-out" 'JP-only-list `BLOCKED`s only'; }
test_jg_ac2_infra_awaiting_go_row_uses_helper() { jg_row_uses_helper "infra AWAITING GO + go" '| `[infra-operator] AWAITING GO` + JP go comment'; }
test_jg_ac2_infra_blocked_go_row_uses_helper() { jg_row_uses_helper "infra planner/operator BLOCKED + go" '**Resume on JP'"'"'s go**'; }
test_jg_ac2_validation_operator_resume_row_uses_helper() { jg_row_uses_helper "validation: operator resume" '| infra-operator (resume) |'; }
test_jg_ac2_validation_blocked_go_row_uses_helper() { jg_row_uses_helper "validation: planner/operator resume on go" '| infra-planner / infra-operator (resume on JP go after `BLOCKED`) |'; }
test_jg_ac2_validation_delegated_decision_row_uses_helper() { jg_row_uses_helper "validation: delegated-decision" '| blocked stage / test-writer / fix cycle (resume on a delegated decision) |'; }

# the prose definition of the exact form lives once, beside the helper
test_jg_ac2_exact_form_spelled_out_once() {  # #310: the definition now names the shared set once
  local n
  n=$(grep -cF -- 'jp_approval_re` in `hooks/pipeline-markers.sh`' "$ORCH_JG")
  assert_eq "$n" "1" "AC2: the exact-form definition appears once (found $n); other rows refer to jp_go" || return 1
}

# ---------------------------------------------------------------------------------------- AC3

# True when one blank-line-separated paragraph of orchestrator.md matches every given ERE (case-insensitive).
# Keeps the AC3 rule as ONE statement, not words scattered across the file (the helper's own comment must not satisfy it).
jg_para_has_all() {
  JG_PATS="$(printf '%s\n' "$@")" awk -v RS= '
    BEGIN { n = split(ENVIRON["JG_PATS"], P, "\n") }
    { ok = 1; for (i = 1; i <= n; i++) if (tolower($0) !~ tolower(P[i])) { ok = 0; break }
      if (ok) { found = 1 } }
    END { exit found ? 0 : 1 }' "$ORCH_JG"
}

test_jg_ac3_no_go_claims_gated_on_helper_output() {
  # One paragraph: names the no-go claims, names jp_go, and allows the claim only after it ran and printed nothing.
  jg_para_has_all 'jp_go' 'no go after it|nothing new has been posted' 'only after' 'exited 0|exit(ed)? 0|succeeded' 'print(ed|s) nothing' \
    || { fail "AC3: one paragraph must allow a 'no go' card / delegated-decision fail only after jp_go ran, exited 0 and printed nothing"; return 1; }
}

test_jg_ac3_failed_lookup_is_not_a_no_go() {
  # One paragraph: non-zero jp_go = failed lookup, reported as such, never treated as no go.
  jg_para_has_all 'jp_go' 'non-zero (exit )?is a failed lookup' 'never (treat|report)[a-z ]* (it )?as "?no go' \
    || { fail "AC3/AC1: one paragraph must say a non-zero jp_go is a failed lookup and is never treated as 'no go'"; return 1; }
}

# ---------------------------------------------------------------------------------------- AC4

test_jg_ac4_marker_and_supervisor_files_unchanged() {
  local base f
  base=$(cd "$ROOT_JG" && git merge-base HEAD origin/main 2>/dev/null)
  assert_ne "$base" "" "AC4: merge-base with origin/main resolves" || return 1
  for f in; do   # host-sync: supervisor.sh pin dropped (it fails any legitimate supervisor change once merged); #310: hooks/pipeline-markers.sh changes (shared matcher), dropped from this pin
    (cd "$ROOT_JG" && git diff --quiet "$base" -- "$f") || { fail "AC4: $f must be unchanged vs origin/main"; return 1; }
  done
}

# AC5 is the behavioural block above. AC6 is a post-deploy observation (runs.jsonl); not testable here.

run_test test_jg_ac1_helper_defined_once_next_to_markers
run_test test_jg_ac1_returns_the_go_and_prints_url_and_timestamp
run_test test_jg_ac1_accepted_forms
run_test test_jg_ac1_rejected_forms
run_test test_jg_ac1_go_from_non_author_ignored
run_test test_jg_ac1_go_dated_before_blocked_ignored
run_test test_jg_ac1_go_at_exact_blocked_timestamp_ignored_and_one_second_later_accepted
run_test test_jg_ac1_prints_every_qualifying_go
run_test test_jg_ac1_go_on_second_page_found
run_test test_jg_ac1_failed_read_prints_nothing_and_returns_nonzero
run_test test_jg_ac1_no_go_on_clean_read_is_distinguishable_from_failure
run_test test_jg_ac2_code_track_carveout_row_uses_helper
run_test test_jg_ac2_infra_awaiting_go_row_uses_helper
run_test test_jg_ac2_infra_blocked_go_row_uses_helper
run_test test_jg_ac2_validation_operator_resume_row_uses_helper
run_test test_jg_ac2_validation_blocked_go_row_uses_helper
run_test test_jg_ac2_validation_delegated_decision_row_uses_helper
run_test test_jg_ac2_exact_form_spelled_out_once
run_test test_jg_ac3_no_go_claims_gated_on_helper_output
run_test test_jg_ac3_failed_lookup_is_not_a_no_go
run_test test_jg_ac4_marker_and_supervisor_files_unchanged
