# Issue #141 AC21 — pipeline-report.sh reads events.jsonl: STAGE OUTCOMES, BLOCKED REASONS, RUN EXITS AND ESCAPES.
# Hand-written events rows; expected numbers are hand arithmetic written in comments. Placeholder names only (public repo).
# Prefix re_ / RE_. Section lines are normalised (":" "=" "," "(" ")" -> blank, blanks collapsed) and are expected to carry
# "<label> <number>" pairs (e.g. "runs 3", "marker 2", "median_dur_s 200" or "median 200").

HERE_RE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RE_SH="$HERE_RE/../pipeline-report.sh"
RE_ROOT=$(cd "$HERE_RE/../../.." && pwd)

# re_end <agent> <outcome> <dur_s> <block_class|null> <ts>
re_end() {
  jq -nc --arg ag "$1" --arg oc "$2" --argjson dur "$3" --arg bc "$4" --arg ts "$5" \
    '{v:1,ts:$ts,host:"vm",event:"stage_end",repo:"project-a/app",issue:42,agent:$ag,outcome:$oc,dur_s:$dur,
      block_class:(if $bc=="null" then null else $bc end),cost_usd:1.0}'
}

# Fixture 1 (--since 2026-09-25):
#   fullstack-developer: marker 100 (null), marker 300 (ci_red), killed 200 (null)  -> runs 3, marker 2, killed 1, median 200
#   code-reviewer:       marker 60 (needs_jp), rate_limited 60 (ci_red)             -> runs 2, marker 1, rate_limited 1, median 60
#   block classes: ci_red 2, needs_jp 1 (highest first)
#   run_exit: normal x1, rate_limited/weekly x1;  escape: project-a/app#42 caused by project-a/lib#7
#   NOT counted: a stage_start row, a stage_end dated 2026-09-01 (fullstack-developer, error, 999 s, class other),
#                an unknown event, one broken line
re_fixture1() {
  {
    re_end fullstack-developer marker 100 null 2026-10-01T10:00:00Z
    re_end fullstack-developer marker 300 ci_red 2026-10-01T10:01:00Z
    re_end fullstack-developer killed 200 null 2026-10-01T10:02:00Z
    re_end code-reviewer marker 60 needs_jp 2026-10-01T10:03:00Z
    re_end code-reviewer rate_limited 60 ci_red 2026-10-01T10:04:00Z
    echo '{"v":1,"ts":"2026-10-01T10:05:00Z","event":"stage_start","repo":"project-a/app","issue":42,"agent":"fullstack-developer"}'
    echo '{"v":1,"ts":"2026-10-01T11:00:00Z","event":"run_exit","repo":"project-a/app","issue":42,"class":"normal","limit_kind":null,"exit_code":0}'
    echo '{"v":1,"ts":"2026-10-01T11:01:00Z","event":"run_exit","repo":"project-a/app","issue":43,"class":"rate_limited","limit_kind":"weekly","exit_code":0}'
    echo '{"v":1,"ts":"2026-10-01T12:00:00Z","event":"escape","repo":"project-a/app","issue":42,"caused_by_repo":"project-a/lib","caused_by_issue":7}'
    re_end fullstack-developer error 999 other 2026-09-01T10:00:00Z
    echo '{"v":1,"ts":"2026-10-01T13:00:00Z","event":"mystery","agent":"fullstack-developer"}'
    echo 'this is { not json'
  } > "$1"
}

# Fixture 2: only stage_* rows
re_fixture2() {
  {
    re_end fullstack-developer marker 100 null 2026-10-01T10:00:00Z
    echo '{"v":1,"ts":"2026-10-01T10:05:00Z","event":"stage_start","repo":"project-a/app","issue":42,"agent":"fullstack-developer"}'
  } > "$1"
}

re_setup() { RE_T=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-re.XXXXXX"); mkdir -p "$RE_T/home"; : > "$RE_T/sessions.jsonl"; }
re_teardown() { rm -rf "$RE_T"; }
# re_run <--events args…> — sets RE_OUT, RE_RC
re_run() {
  RE_OUT=$(HOME="$RE_T/home" "$RE_SH" --no-gh --sessions "$RE_T/sessions.jsonl" --since 2026-09-25 "$@" 2>/dev/null); RE_RC=$?
}
RE_HEADS='STAGE OUTCOMES|BLOCKED REASONS|RUN EXITS AND ESCAPES|PIPELINE REPORT|COST BY AGENT|TOP 5 TICKETS|CACHE HIT|COST BY MODEL|OPUS IN NON-OPUS|GITHUB TRAILS'
# re_section <heading> — normalised body lines between this heading and the next known heading
re_section() {
  printf '%s\n' "$RE_OUT" | tr ':=,()' '     ' | tr -s ' \t' ' ' | awk -v h="$1" -v heads="$RE_HEADS" '
    BEGIN { n = split(heads, H, "|") }
    { t = $0; sub(/^ /, "", t); isH = 0; for (i = 1; i <= n; i++) if (index(t, H[i]) == 1) isH = 1 }
    isH { on = (index(t, h) == 1); next }
    on { print }'
}
re_line() { printf '%s\n' "$1" | grep -E "^ ?$2( |\$)" | head -1; }

test_re_ac21_stage_outcomes_per_agent() {
  re_setup; re_fixture1 "$RE_T/e.jsonl"; re_run --events "$RE_T/e.jsonl"
  local sec fd cr r=0
  sec=$(re_section 'STAGE OUTCOMES')
  assert_exit0 "$RE_RC" "AC21: exit 0" || r=1
  fd=$(re_line "$sec" fullstack-developer); cr=$(re_line "$sec" code-reviewer)
  [ -n "$fd" ] || { fail "AC21: no fullstack-developer line in STAGE OUTCOMES:
$sec"; re_teardown; return 1; }
  [ -n "$cr" ] || { fail "AC21: no code-reviewer line in STAGE OUTCOMES"; re_teardown; return 1; }
  printf '%s' "$fd" | grep -Eq 'runs 3( |$)' || { fail "AC21: fullstack-developer runs 3 (old row excluded) in [$fd]"; r=1; }
  printf '%s' "$fd" | grep -Eq 'marker 2( |$)' || { fail "AC21: fullstack-developer marker 2 in [$fd]"; r=1; }
  printf '%s' "$fd" | grep -Eq 'killed 1( |$)' || { fail "AC21: fullstack-developer killed 1 in [$fd]"; r=1; }
  printf '%s' "$fd" | grep -Eq 'error 1( |$)' && { fail "AC21: the 2026-09-01 error row must not be counted in [$fd]"; r=1; }
  printf '%s' "$fd" | grep -Eq 'median[a-z_ ]* 200( |$)' || { fail "AC21: fullstack-developer median dur 200 (100,200,300) in [$fd]"; r=1; }
  printf '%s' "$cr" | grep -Eq 'runs 2( |$)' || { fail "AC21: code-reviewer runs 2 in [$cr]"; r=1; }
  printf '%s' "$cr" | grep -Eq 'marker 1( |$)' || { fail "AC21: code-reviewer marker 1 in [$cr]"; r=1; }
  printf '%s' "$cr" | grep -Eq 'rate_limited 1( |$)' || { fail "AC21: code-reviewer rate_limited 1 in [$cr]"; r=1; }
  printf '%s' "$cr" | grep -Eq 'median[a-z_ ]* 60( |$)' || { fail "AC21: code-reviewer median dur 60 in [$cr]"; r=1; }
  # the three sections come after the existing ones
  local a b; a=$(printf '%s\n' "$RE_OUT" | grep -n 'OPUS IN NON-OPUS' | head -1 | cut -d: -f1); b=$(printf '%s\n' "$RE_OUT" | grep -n 'STAGE OUTCOMES' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] || { fail "AC21: STAGE OUTCOMES must come after the existing sections"; r=1; }
  re_teardown; return $r
}

test_re_ac21_blocked_reasons_counts_highest_first() {
  re_setup; re_fixture1 "$RE_T/e.jsonl"; re_run --events "$RE_T/e.jsonl"
  local sec first second r=0
  sec=$(re_section 'BLOCKED REASONS')
  first=$(printf '%s\n' "$sec" | grep -E '[a-z_]+ [0-9]+' | sed -n 1p); second=$(printf '%s\n' "$sec" | grep -E '[a-z_]+ [0-9]+' | sed -n 2p)
  printf '%s' "$first" | grep -Eq 'ci_red 2( |$)' || { fail "AC21: first line is ci_red 2 (highest first), got [$first]"; r=1; }
  printf '%s' "$second" | grep -Eq 'needs_jp 1( |$)' || { fail "AC21: second line is needs_jp 1, got [$second]"; r=1; }
  assert_not_contains "$sec" "other" "AC21: the out-of-window row's class 'other' is not counted" || r=1
  assert_eq "$(printf '%s\n' "$sec" | grep -Ec '[a-z_]+ [0-9]+')" "2" "AC21: exactly two classes listed (null classes skipped)" || r=1
  re_teardown; return $r
}

test_re_ac21_run_exits_and_escapes() {
  re_setup; re_fixture1 "$RE_T/e.jsonl"; re_run --events "$RE_T/e.jsonl"
  local sec r=0
  sec=$(re_section 'RUN EXITS AND ESCAPES')
  printf '%s\n' "$sec" | grep -Eq '(^| )normal 1( |$)' || { fail "AC21: normal 1 in:
$sec"; r=1; }
  printf '%s\n' "$sec" | grep -E 'rate_limited' | grep -E 'weekly' | grep -Eq '(^| )1( |$)' || { fail "AC21: rate_limited split by limit_kind weekly, count 1, in:
$sec"; r=1; }
  assert_contains "$sec" "project-a/app#42 caused by project-a/lib#7" "AC21: the escape line" || r=1
  assert_not_contains "$sec" "mystery" "AC21: unknown event ignored" || r=1
  assert_eq "$(grep -c 'runs\.jsonl' "$RE_SH")" "0" "AC21: the report still never reads runs.jsonl" || r=1
  re_teardown; return $r
}

test_re_ac21_events_option_is_repeatable_and_merges() {
  re_setup; re_fixture1 "$RE_T/e1.jsonl"
  re_end code-reviewer error 60 null 2026-10-02T10:00:00Z > "$RE_T/e2.jsonl"   # code-reviewer: 3 runs (60,60,60), error 1
  re_run --events "$RE_T/e1.jsonl" --events "$RE_T/e2.jsonl"
  local cr r=0; cr=$(re_line "$(re_section 'STAGE OUTCOMES')" code-reviewer)
  printf '%s' "$cr" | grep -Eq 'runs 3( |$)' || { fail "repeatable --events: code-reviewer runs 3 in [$cr]"; r=1; }
  printf '%s' "$cr" | grep -Eq 'error 1( |$)' || { fail "repeatable --events: code-reviewer error 1 in [$cr]"; r=1; }
  re_teardown; return $r
}

test_re_ac21_only_stage_rows_prints_zero_exits_and_none_escapes() {
  re_setup; re_fixture2 "$RE_T/e.jsonl"; re_run --events "$RE_T/e.jsonl"
  local sec r=0; sec=$(re_section 'RUN EXITS AND ESCAPES')
  assert_exit0 "$RE_RC" "AC21 fixture 2: exit 0" || r=1
  printf '%s\n' "$sec" | grep -Eq '(^| )0( |$)' || { fail "AC21 fixture 2: a zero run-exit count in:
$sec"; r=1; }
  printf '%s\n' "$sec" | grep -Eq '(^| )none( |$)' || { fail "AC21 fixture 2: escapes print none in:
$sec"; r=1; }
  re_teardown; return $r
}

test_re_ac21_no_events_file_prints_no_events_file_and_exits_0() {
  re_setup; re_run --events "$RE_T/does-not-exist.jsonl"
  local r=0
  assert_exit0 "$RE_RC" "AC21 no file: exit 0" || r=1
  assert_contains "$(re_section 'STAGE OUTCOMES')" "no events file" "AC21 no file: 'no events file' under STAGE OUTCOMES" || r=1
  re_teardown; return $r
}

for t in test_re_ac21_stage_outcomes_per_agent test_re_ac21_blocked_reasons_counts_highest_first \
  test_re_ac21_run_exits_and_escapes test_re_ac21_events_option_is_repeatable_and_merges \
  test_re_ac21_only_stage_rows_prints_zero_exits_and_none_escapes test_re_ac21_no_events_file_prints_no_events_file_and_exits_0; do
  run_test "$t"
done
