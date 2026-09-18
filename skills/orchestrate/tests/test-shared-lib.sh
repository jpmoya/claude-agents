# Issue #8 — shared helpers live once in pipeline-lib.sh; the marker jq expression is defined once
# (marker_last_jq) and used by both launchers; the two Slack keys are documented. Nothing about the
# launchers' observable behavior may change (the AC14 golden and the AC12 bridge test stay green).
#
# Portability note: test-ac11 scans every test-*.sh for the lowercase words that name the
# forbidden constructs, so this file spells them with a bracket in the middle (a one-character
# class) and only ever greps the uppercase SETSID= assignment.

HERE_SL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_SL="$HERE_SL/.."
ROOT_SL=$(cd "$HERE_SL/../../.." && pwd)
LIB_SL="$RS_SL/pipeline-lib.sh"
MARKERS_SL="$ROOT_SL/hooks/pipeline-markers.sh"

# sl_marker_expr — prints marker_last_jq's output, sourced in a subshell (no gh call involved).
sl_marker_expr() {
  ( . "$LIB_SL" && . "$MARKERS_SL" && marker_last_jq ) 2>/dev/null
}

# sl_check_marker_expr <comments-json-array> <expected-line> <label> — runs the expression through
# real jq against the {"comments":[...]} shape `gh issue view --json comments` produces.
sl_check_marker_expr() {
  local comments=$1 expected=$2 label=$3 expr actual
  expr=$(sl_marker_expr)
  assert_ne "$expr" "" "$label: marker_last_jq must print a jq expression (pipeline-lib.sh: NotImplemented / missing)" || return 1
  actual=$(printf '{"comments":%s}' "$comments" | jq -r "$expr" 2>&1)
  assert_eq "$actual" "$expected" "$label" || return 1
}

# ---------------------------------------------------------------------------
# AC2 — marker_last_jq, four ticket fixtures + two first-line/NOTE edge cases
# ---------------------------------------------------------------------------

test_sl_marker_expr_real_marker_beats_later_note() {
  # ticket fixture: READY FOR ENGINEERING then a NOTE -> NOTE is inert
  sl_check_marker_expr \
    '[{"body":"**[product-manager] READY FOR ENGINEERING**\nx"},{"body":"**[product-manager] NOTE**\nhi"}]' \
    '**[product-manager] READY FOR ENGINEERING**' \
    "AC2: a NOTE after a real marker must not become the latest marker"
}

test_sl_marker_expr_off_vocabulary_first_line_is_none() {
  # ticket fixture (negative): the literal word MARKER is not routing state
  sl_check_marker_expr \
    '[{"body":"**[deployer] MARKER** PASS"}]' \
    'none' \
    "AC2: an off-vocabulary first line must yield none"
}

test_sl_marker_expr_no_comments_is_none() {
  sl_check_marker_expr '[]' 'none' "AC2: no comments must yield none"
}

test_sl_marker_expr_two_real_markers_newest_wins() {
  # ticket fixture: two real markers, older first -> the newer one
  sl_check_marker_expr \
    '[{"body":"**[product-manager] READY FOR ENGINEERING**\nx"},{"body":"**[test-writer] TESTS WRITTEN**\ny"}]' \
    '**[test-writer] TESTS WRITTEN**' \
    "AC2: with two real markers the newer (later) one must win"
}

test_sl_marker_expr_only_first_line_counts() {
  # existing behavior (split on newline, take line 1): a marker on line 2 is not a marker
  sl_check_marker_expr \
    '[{"body":"chatter\n**[test-writer] TESTS WRITTEN**"}]' \
    'none' \
    "AC2: only the first line of a comment can be a routing marker"
}

test_sl_marker_expr_off_vocabulary_after_real_marker_keeps_real() {
  sl_check_marker_expr \
    '[{"body":"**[code-reviewer] PASS**\nok"},{"body":"**[deployer] MARKER** PASS"}]' \
    '**[code-reviewer] PASS**' \
    "AC2: a later off-vocabulary line must not displace the newest real marker"
}

# ---------------------------------------------------------------------------
# AC1 — each helper defined exactly once, in pipeline-lib.sh; both launchers source it
# ---------------------------------------------------------------------------

# sl_defined_once <ERE> <label> — the pattern matches exactly one line across skills/orchestrate/*.sh
# and that line is in pipeline-lib.sh.
sl_defined_once() {
  local pat=$1 label=$2 hits n
  hits=$(grep -HE "$pat" "$RS_SL"/*.sh 2>/dev/null || true)
  n=$(printf '%s' "$hits" | grep -c . || true)
  assert_eq "$n" "1" "$label: expected exactly one definition in skills/orchestrate/*.sh, found: [$hits]" || return 1
  assert_contains "$hits" "pipeline-lib.sh:" "$label: the single definition must live in pipeline-lib.sh, found: [$hits]" || return 1
}

test_sl_count_running_defined_once_in_lib()    { sl_defined_once '^count_running\(\)'    "AC1 count_running"; }
test_sl_mem_available_mb_defined_once_in_lib() { sl_defined_once '^mem_available_mb\(\)' "AC1 mem_available_mb"; }
test_sl_has_capacity_defined_once_in_lib()     { sl_defined_once '^has_capacity\(\)'     "AC1 has_capacity"; }
test_sl_setsid_probe_defined_once_in_lib()     { sl_defined_once '^SETSID='              "AC1 SETSID probe"; }

test_sl_both_launchers_source_the_lib() {
  local f hit
  for f in orchestrate.sh supervisor.sh; do
    hit=$(grep -E '^[[:space:]]*(source|\.)[[:space:]].*pipeline-lib\.sh' "$RS_SL/$f" 2>/dev/null || true)
    assert_ne "$hit" "" "AC1: $f must source pipeline-lib.sh" || return 1
  done
}

# ---------------------------------------------------------------------------
# AC1 (behavior of the moved helpers, sourced from the lib) — boundaries: 0 / at max / under max
# ---------------------------------------------------------------------------

test_sl_count_running_counts_only_live_pids() {
  local pipe repo n
  pipe=$(new_pipe); repo=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  mk_running "$pipe" 101 "$repo"
  mk_running "$pipe" 102 "$repo"
  mk_dead_pid "$pipe" 103            # pid file present but process dead: must not count
  n=$( . "$LIB_SL" 2>/dev/null; PIPE="$pipe"; count_running 2>/dev/null )
  cleanup_running; rm -rf "$pipe" "$repo"
  assert_eq "$n" "2" "AC1: count_running counts live pids only (2 live + 1 dead = 2)" || return 1
}

test_sl_count_running_empty_pipe_is_zero() {
  local pipe n
  pipe=$(new_pipe)
  n=$( . "$LIB_SL" 2>/dev/null; PIPE="$pipe"; count_running 2>/dev/null )
  rm -rf "$pipe"
  assert_eq "$n" "0" "AC1: count_running on an empty PIPE is 0" || return 1
}

# sl_has_capacity <pipe> <max> <floor> — exit code of has_capacity with those caps
sl_has_capacity() {
  ( . "$LIB_SL" 2>/dev/null; PIPE="$1"; MAX_CONCURRENT="$2"; MEM_FLOOR_MB="$3"; has_capacity ) >/dev/null 2>&1
}

test_sl_has_capacity_boundary_at_max_concurrent() {
  local pipe repo rc_full rc_room
  pipe=$(new_pipe); repo=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  mk_running "$pipe" 101 "$repo"
  mk_running "$pipe" 102 "$repo"
  sl_has_capacity "$pipe" 2 0; rc_full=$?     # 2 running, cap 2 -> no capacity
  sl_has_capacity "$pipe" 3 0; rc_room=$?     # 2 running, cap 3 -> capacity (memory floor 0 always met)
  cleanup_running; rm -rf "$pipe" "$repo"
  assert_eq "$rc_full" "1" "AC1: has_capacity must return 1 (false) when running == MAX_CONCURRENT" || return 1
  assert_eq "$rc_room" "0" "AC1: has_capacity must be true when running == MAX_CONCURRENT - 1 and memory is above the floor" || return 1
}

test_sl_has_capacity_false_when_memory_below_floor() {
  local pipe rc
  pipe=$(new_pipe)
  sl_has_capacity "$pipe" 3 999999999; rc=$?   # nothing running, but the floor exceeds any real RAM
  rm -rf "$pipe"
  assert_eq "$rc" "1" "AC1: has_capacity must return 1 (false) when available memory is below MEM_FLOOR_MB" || return 1
}

test_sl_mem_available_mb_prints_a_positive_integer() {
  local out
  out=$( . "$LIB_SL" 2>/dev/null; mem_available_mb 2>/dev/null )
  case "$out" in ''|*[!0-9]*) fail "AC1: mem_available_mb must print an integer number of MB, got [$out]"; return 1 ;; esac
  assert_ne "$out" "0" "AC1: mem_available_mb must report non-zero available memory on a running host" || return 1
}

# ---------------------------------------------------------------------------
# AC2 — neither launcher keeps the inline marker expression
# ---------------------------------------------------------------------------

test_sl_no_inline_marker_expression_in_launchers() {
  local f hit
  for f in orchestrate.sh supervisor.sh; do
    hit=$(grep -nF 'split(\"\n\")' "$RS_SL/$f" 2>/dev/null || true)
    assert_eq "$hit" "" "AC2: $f must not contain the inline split(\\\"\\n\\\") marker expression — use marker_last_jq" || return 1
  done
}

# ---------------------------------------------------------------------------
# AC2/AC3 — supervisor.sh latest_marker()/issue_is_closed(): one gh call each, expression from
# marker_last_jq, `|| echo "?"` fallback kept. The two functions are lifted out of supervisor.sh
# (running a whole tick is heavy and side-effecting) and run against a call-logging stub gh.
# ---------------------------------------------------------------------------

# sl_mk_stub_gh <dir> — <dir>/bin/gh: appends "$1 $2" to <dir>/calls.log, saves the --jq and --json
# arguments of call N to <dir>/jq-N.txt / json-N.txt, applies --jq to <dir>/reply.json with real jq
# (like gh does), and exits 1 when <dir>/fail exists.
sl_mk_stub_gh() {
  local d=$1
  mkdir -p "$d/bin"
  : > "$d/calls.log"
  cat > "$d/bin/gh" <<'GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
echo "$1 $2" >> "$D/calls.log"
n=$(wc -l < "$D/calls.log" | tr -d ' ')
prev=""; expr=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && { expr=$a; printf '%s' "$a" > "$D/jq-$n.txt"; }
  [ "$prev" = "--json" ] && printf '%s' "$a" > "$D/json-$n.txt"
  prev=$a
done
[ -e "$D/fail" ] && exit 1
if [ -n "$expr" ]; then jq -r "$expr" < "$D/reply.json"; else cat "$D/reply.json"; fi
GH_EOF
  chmod +x "$d/bin/gh"
}

# sl_sup_call <dir> <shell-snippet> — sources the lib + vocabulary, defines supervisor.sh's
# latest_marker() and issue_is_closed() (verbatim text ranges), runs the snippet with the stub gh first on PATH.
sl_sup_call() {
  local d=$1 snippet=$2 fns
  fns=$(awk '/^latest_marker\(\) \{/,/^\}/; /^issue_is_closed\(\) \{/,/^\}/' "$RS_SL/supervisor.sh")
  ( PATH="$d/bin:$PATH"
    . "$LIB_SL" 2>/dev/null; . "$MARKERS_SL"
    eval "$fns"
    eval "$snippet" )
}

test_sl_supervisor_latest_marker_one_gh_call_with_shared_expression() {
  local d expr out calls
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sl.XXXXXX"); sl_mk_stub_gh "$d"
  printf '%s' '{"state":"OPEN","comments":[{"body":"**[test-writer] TESTS WRITTEN**\nx"},{"body":"**[supervisor] NOTE**\ny"}]}' > "$d/reply.json"
  expr=$(sl_marker_expr)
  out=$(sl_sup_call "$d" "latest_marker '$d' 7" 2>/dev/null)
  calls=$(cat "$d/calls.log")
  assert_ne "$expr" "" "AC2: marker_last_jq must print an expression" || { rm -rf "$d"; return 1; }
  assert_eq "$out" "**[test-writer] TESTS WRITTEN**" "AC3: latest_marker returns the newest real marker (NOTE inert)" || { rm -rf "$d"; return 1; }
  assert_eq "$calls" "issue view" "AC3: latest_marker makes exactly one gh call (an 'issue view')" || { rm -rf "$d"; return 1; }
  assert_contains "$(cat "$d/jq-1.txt" 2>/dev/null)" "$expr" "AC2: latest_marker's --jq argument must be marker_last_jq's output" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_sl_supervisor_latest_marker_gh_failure_prints_question_mark() {
  local d expr out calls
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sl.XXXXXX"); sl_mk_stub_gh "$d"
  printf '%s' '{"state":"OPEN","comments":[]}' > "$d/reply.json"
  : > "$d/fail"
  expr=$(sl_marker_expr)
  out=$(sl_sup_call "$d" "latest_marker '$d' 7" 2>/dev/null)
  calls=$(cat "$d/calls.log")
  assert_ne "$expr" "" "AC2: marker_last_jq must print an expression" || { rm -rf "$d"; return 1; }
  assert_eq "$out" "?" "AC3: latest_marker keeps its || echo ? fallback when gh fails" || { rm -rf "$d"; return 1; }
  assert_eq "$calls" "issue view" "AC3: a failing gh is still exactly one call (no retry, no second lookup)" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_sl_supervisor_issue_is_closed_one_gh_call_each() {
  local d rc_closed rc_open calls
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sl.XXXXXX"); sl_mk_stub_gh "$d"
  printf '%s' '{"state":"CLOSED","comments":[]}' > "$d/reply.json"
  sl_sup_call "$d" "issue_is_closed '$d' 7" >/dev/null 2>&1; rc_closed=$?
  printf '%s' '{"state":"OPEN","comments":[]}' > "$d/reply.json"
  sl_sup_call "$d" "issue_is_closed '$d' 7" >/dev/null 2>&1; rc_open=$?
  calls=$(cat "$d/calls.log")
  rm -rf "$d"
  assert_eq "$rc_closed" "0" "AC3: issue_is_closed is true for a CLOSED issue" || return 1
  assert_eq "$rc_open" "1" "AC3: issue_is_closed is false for an OPEN issue" || return 1
  assert_eq "$calls" "issue view
issue view" "AC3: issue_is_closed makes exactly one gh call per invocation (2 invocations = 2 calls)" || return 1
}

# ---------------------------------------------------------------------------
# AC2/AC3 — orchestrate.sh status: still ONE combined `gh issue view --json state,comments` per
# run, with --jq built from marker_last_jq. Stub gh lives in an isolated HOME's .local/bin (which
# config.sh puts first on PATH), so no real gh can shadow it; tests/bin/gh is not touched.
# The stub applies the --jq argument with REAL jq to a per-issue reply file (like gh does), so the
# composed `{state, last: (...)}` expression is actually evaluated, not just string-matched.
# ---------------------------------------------------------------------------

# sl_status_setup — builds a 2-run fixture (#101 OPEN, #102 CLOSED) and runs `orchestrate.sh status`
# once. Sets SL_PIPE SL_HOME SL_REPO_A SL_REPO_B SL_D (stub dir) SL_OUT (combined stdout+stderr).
# Reply files (gh-json shape): #101 = a real marker followed by a NOTE; #102 = CLOSED, no comments.
sl_status_setup() {
  SL_PIPE=$(new_pipe); SL_HOME=$(new_home)
  SL_REPO_A=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX"); SL_REPO_B=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  SL_D="$SL_HOME/.local/bin"; mkdir -p "$SL_D"
  cat > "$SL_D/gh" <<'GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
echo "$1 $2" >> "$D/calls.log"
n=$(wc -l < "$D/calls.log" | tr -d ' ')
prev=""; expr=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && { expr=$a; printf '%s' "$a" > "$D/jq-$n.txt"; }
  [ "$prev" = "--json" ] && printf '%s' "$a" > "$D/json-$n.txt"
  prev=$a
done
if [ "$1" = "issue" ] && [ "$2" = "view" ] && [ -f "$D/reply-$3.json" ]; then
  if [ -n "$expr" ]; then jq -c "$expr" < "$D/reply-$3.json"; else cat "$D/reply-$3.json"; fi
  exit $?
fi
echo "stub gh: unexpected invocation: $*" >&2; exit 1
GH_EOF
  chmod +x "$SL_D/gh"; : > "$SL_D/calls.log"
  printf '%s' '{"state":"OPEN","comments":[{"body":"**[test-writer] TESTS WRITTEN**\nx"},{"body":"**[supervisor] NOTE**\ny"}]}' > "$SL_D/reply-101.json"
  printf '%s' '{"state":"CLOSED","comments":[]}' > "$SL_D/reply-102.json"
  mk_running "$SL_PIPE" 101 "$SL_REPO_A"
  mk_running "$SL_PIPE" 102 "$SL_REPO_B"
  SL_OUT=$( HOME="$SL_HOME" PATH="$SL_D:$PATH" PIPE="$SL_PIPE" QUEUE="$SL_PIPE/queue" "$RS_SL/orchestrate.sh" status 2>&1 )
  cleanup_running
}

sl_status_cleanup() { rm -rf "$SL_PIPE" "$SL_HOME" "$SL_REPO_A" "$SL_REPO_B"; }

# Call shape: exactly one `gh issue view --json state,comments` per run, --jq from marker_last_jq.
test_sl_status_one_gh_issue_view_per_run_using_shared_expression() {
  local expr ncalls nview i
  sl_status_setup
  expr=$(sl_marker_expr)
  ncalls=$(wc -l < "$SL_D/calls.log" | tr -d ' ')
  nview=$(grep -c '^issue view$' "$SL_D/calls.log" || true)
  assert_ne "$expr" "" "AC2: marker_last_jq must print an expression" || { sl_status_cleanup; return 1; }
  assert_eq "$ncalls" "2" "AC3: status over 2 runs makes exactly 2 gh calls in total" || { sl_status_cleanup; return 1; }
  assert_eq "$nview" "2" "AC3: both are 'gh issue view' (one per run)" || { sl_status_cleanup; return 1; }
  for i in 1 2; do
    assert_eq "$(cat "$SL_D/json-$i.txt" 2>/dev/null)" "state,comments" "AC3: call $i keeps the single combined --json state,comments" || { sl_status_cleanup; return 1; }
    assert_contains "$(cat "$SL_D/jq-$i.txt" 2>/dev/null)" "$expr" "AC2: call $i's --jq must contain marker_last_jq's output" || { sl_status_cleanup; return 1; }
  done
  sl_status_cleanup
}

# Printed output: the composed --jq is evaluated by real jq. A real marker followed by a NOTE shows
# the real marker (NOTE inert); a CLOSED issue overrides the local state. Expected strings: ticket
# fixture (marker beats later NOTE) and the existing status format `latest marker: <first line>`.
test_sl_status_prints_latest_real_marker_from_evaluated_jq() {
  local line
  sl_status_setup
  line=$(printf '%s\n' "$SL_OUT" | grep '^#101 ' || true)
  sl_status_cleanup
  assert_contains "$line" "#101  running" "AC3: status still prints run 101 as running (issue OPEN)" || return 1
  assert_contains "$line" "latest marker: **[test-writer] TESTS WRITTEN**  log=" "AC2/AC3: status shows the newest real marker, not the later NOTE, from the evaluated --jq" || return 1
}

test_sl_status_closed_issue_overrides_local_state() {
  local line
  sl_status_setup
  line=$(printf '%s\n' "$SL_OUT" | grep '^#102 ' || true)
  sl_status_cleanup
  assert_contains "$line" "#102  done (issue closed)" "AC3: status still reports a CLOSED issue as done (issue closed), from the evaluated --jq's state field" || return 1
  assert_contains "$line" "latest marker: none  log=" "AC3: a CLOSED issue with no comments shows latest marker: none" || return 1
}

# ---------------------------------------------------------------------------
# AC5 — Slack keys documented: config.local.example.sh, install.sh todo()s, README install paragraph
# ---------------------------------------------------------------------------

test_sl_example_config_documents_both_slack_keys_as_commented_placeholders() {
  local f="$RS_SL/config.local.example.sh" key
  for key in SLACK_BOT_TOKEN SLACK_ENGINEERING_CHANNEL; do
    assert_ne "$(grep -nE "^# $key=" "$f" 2>/dev/null || true)" "" "AC5: config.local.example.sh must carry a commented '# $key=' line" || return 1
  done
  assert_eq "$(grep -nE 'xox[a-z]-[0-9A-Za-z]' "$f" 2>/dev/null || true)" "" "AC5: config.local.example.sh must hold placeholder values only (no xox*- token shape)" || return 1
}

test_sl_example_config_notes_notify_engineering_is_silent_noop() {
  local hit
  hit=$(grep -inE 'notify_engineering.*no-op|no-op.*notify_engineering' "$RS_SL/config.local.example.sh" 2>/dev/null || true)
  assert_ne "$hit" "" "AC5: config.local.example.sh must note that notify_engineering() is a silent no-op until both keys are set" || return 1
}

test_sl_example_config_slack_keys_sit_next_to_the_webhook_key() {
  local f="$RS_SL/config.local.example.sh" w t c
  w=$(grep -nE 'SLACK_WEBHOOK_URL=' "$f" | head -1 | cut -d: -f1)
  t=$(grep -nE '^# SLACK_BOT_TOKEN=' "$f" | head -1 | cut -d: -f1)
  c=$(grep -nE '^# SLACK_ENGINEERING_CHANNEL=' "$f" | head -1 | cut -d: -f1)
  [ -n "$w" ] && [ -n "$t" ] && [ -n "$c" ] || { fail "AC5: webhook/token/channel lines must all exist in config.local.example.sh (got w=[$w] t=[$t] c=[$c])"; return 1; }
  # "next to the existing Slack key": within 8 lines either side (room for the note + a blank line)
  [ $((t - w)) -le 8 ] && [ $((w - t)) -le 8 ] && [ $((c - w)) -le 8 ] && [ $((w - c)) -le 8 ] \
    || { fail "AC5: SLACK_BOT_TOKEN (line $t) and SLACK_ENGINEERING_CHANNEL (line $c) must sit within 8 lines of SLACK_WEBHOOK_URL (line $w)"; return 1; }
}

test_sl_install_sh_todos_each_unset_slack_key_unconditionally() {
  local f="$RS_SL/install.sh" key line
  for key in SLACK_BOT_TOKEN SLACK_ENGINEERING_CHANNEL; do
    line=$(grep -E "todo[[:space:]]*\"[^\"]*$key" "$f" 2>/dev/null || true)
    assert_ne "$line" "" "AC5: install.sh must todo() $key" || return 1
    assert_contains "$line" "-z \"\${$key:-}\"" "AC5: install.sh's $key todo must fire only when the key is unset (-z \"\${$key:-}\")" || return 1
    assert_not_contains "$line" "SCAN" "AC5: install.sh's $key todo must not be gated on --scan" || return 1
  done
}

test_sl_readme_install_paragraph_mentions_bot_token_and_channel() {
  local line
  line=$(grep -F 'Secrets go only in' "$ROOT_SL/README.md" 2>/dev/null || true)
  assert_ne "$line" "" "AC5: README.md's install paragraph ('Secrets go only in ...') must still exist" || return 1
  assert_contains "$line" "SLACK_BOT_TOKEN" "AC5: the README secrets sentence must mention SLACK_BOT_TOKEN" || return 1
  assert_contains "$line" "SLACK_ENGINEERING_CHANNEL" "AC5: the README secrets sentence must mention SLACK_ENGINEERING_CHANNEL" || return 1
}

# ---------------------------------------------------------------------------
# AC6 — launch blocks untouched (regression guard, green before and after; the bridge comment is
# already pinned by test_ac12_supervisor_comment_updated in test-pipeline-bridge-dispatch.sh)
# ---------------------------------------------------------------------------

test_sl_both_launch_blocks_still_present_once() {
  local f n
  for f in orchestrate.sh supervisor.sh; do
    n=$(grep -c -- '--dangerously-skip-permissions --agent orchestrator -p "\$1"' "$RS_SL/$f" || true)
    assert_eq "$n" "1" "AC6: $f must keep exactly one 'claude ... --agent orchestrator -p' launch line" || return 1
  done
  assert_contains "$(cat "$RS_SL/supervisor.sh")" '2>&1 9>&- &' "AC6: supervisor.sh's launch block keeps its 9>&- fd close" || return 1
}

# ---------------------------------------------------------------------------
# AC7 — portability of the new lib (bash 3.2 floor; no GNU-only flags; SETSID= probe line exempt)
# ---------------------------------------------------------------------------

test_sl_lib_has_no_forbidden_or_bash4_syntax() {
  local re4 hits
  re4='\bfl[o]ck\b|\bset[s]id\b|declare[[:space:]]+-[A]\b|date[[:space:]]+-[d][[:space:]]|date[[:space:]]+-[r][[:space:]]|stat[[:space:]]+-[c][[:space:]]|stat[[:space:]]+-[f][[:space:]]|readlink[[:space:]]+-[f]\b'
  re4="$re4"'|\bmap[f]ile\b|\bread[a]rray\b|\$\{[A-Za-z_]+(,,|\^\^)\}|&>>|\|&'
  [ -f "$LIB_SL" ] || { fail "AC7: pipeline-lib.sh must exist"; return 1; }
  grep -qE '^has_capacity\(\)' "$LIB_SL" || { fail "AC7: pipeline-lib.sh must hold the moved helpers before its syntax is worth checking (no has_capacity found)"; return 1; }
  hits=$(grep -vE '^SETSID=' "$LIB_SL" | grep -nE "$re4" || true)
  assert_eq "$hits" "" "AC7: pipeline-lib.sh (other than the moved SETSID= probe line) must contain no forbidden / bash-4-only syntax" || return 1
}

run_test test_sl_marker_expr_real_marker_beats_later_note
run_test test_sl_marker_expr_off_vocabulary_first_line_is_none
run_test test_sl_marker_expr_no_comments_is_none
run_test test_sl_marker_expr_two_real_markers_newest_wins
run_test test_sl_marker_expr_only_first_line_counts
run_test test_sl_marker_expr_off_vocabulary_after_real_marker_keeps_real
run_test test_sl_count_running_defined_once_in_lib
run_test test_sl_mem_available_mb_defined_once_in_lib
run_test test_sl_has_capacity_defined_once_in_lib
run_test test_sl_setsid_probe_defined_once_in_lib
run_test test_sl_both_launchers_source_the_lib
run_test test_sl_count_running_counts_only_live_pids
run_test test_sl_count_running_empty_pipe_is_zero
run_test test_sl_has_capacity_boundary_at_max_concurrent
run_test test_sl_has_capacity_false_when_memory_below_floor
run_test test_sl_mem_available_mb_prints_a_positive_integer
run_test test_sl_no_inline_marker_expression_in_launchers
run_test test_sl_supervisor_latest_marker_one_gh_call_with_shared_expression
run_test test_sl_supervisor_latest_marker_gh_failure_prints_question_mark
run_test test_sl_supervisor_issue_is_closed_one_gh_call_each
run_test test_sl_status_one_gh_issue_view_per_run_using_shared_expression
run_test test_sl_status_prints_latest_real_marker_from_evaluated_jq
run_test test_sl_status_closed_issue_overrides_local_state
run_test test_sl_example_config_documents_both_slack_keys_as_commented_placeholders
run_test test_sl_example_config_notes_notify_engineering_is_silent_noop
run_test test_sl_example_config_slack_keys_sit_next_to_the_webhook_key
run_test test_sl_install_sh_todos_each_unset_slack_key_unconditionally
run_test test_sl_readme_install_paragraph_mentions_bot_token_and_channel
run_test test_sl_both_launch_blocks_still_present_once
run_test test_sl_lib_has_no_forbidden_or_bash4_syntax
