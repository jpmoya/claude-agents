# Incident review agents (issue #27): agents/pipeline-diagnostician.md + agents/pipeline-adjudicator.md.
# The two definitions are prose, so the contract is pinned by literal strings: frontmatter values,
# the ordered method lead-ins, the decision rules, the byte-for-byte verdict card, and the doc
# paragraphs that tell a session when to run them. One guard case proves they stay out of the
# pipeline's routing files (they are on-demand agents, not stages).
# Issue #32: the verdict record lives on the GitHub tickets themselves (proposal issue, incident
# issue, or the fix ticket's body) — there is no separate log issue, and both agents use Bash for
# reading only.
# Nothing here touches the network, gh, ssh or /tmp/pipeline: every case reads tracked files only.

HERE_IR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_IR=$(cd "$HERE_IR/../../.." && pwd)
DIAG_IR="$ROOT_IR/agents/pipeline-diagnostician.md"
ADJ_IR="$ROOT_IR/agents/pipeline-adjudicator.md"

# ir_frontmatter <file> — prints the lines between the first two `---` lines.
ir_frontmatter() {
  awk '/^---$/ { n++; next } n == 1 { print } n >= 2 { exit }' "$1"
}

# ir_has <file> <literal> — fixed-string search; fails with the missing literal named.
ir_has() {
  grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }
}

# ir_frontmatter_ok <file> <name> <effort> — AC1 for one agent file.
ir_frontmatter_ok() {
  local file=$1 name=$2 effort=$3 fm keys tools bad
  assert_file_exists "$file" "agent definition" || return 1
  fm=$(ir_frontmatter "$file")
  keys=$(printf '%s\n' "$fm" | sed 's/:.*//' | sort | tr '\n' ' ')
  assert_eq "$keys" "description effort model name tools " "$name frontmatter keys" || return 1
  for line in "name: $name" "tools: Bash, Read, Grep, Glob" "model: opus" "effort: $effort"; do
    printf '%s\n' "$fm" | grep -qxF -- "$line" || { fail "$name frontmatter: missing exact line [$line]"; return 1; }
  done
  tools=$(printf '%s\n' "$fm" | grep '^tools:')
  for bad in Write Edit Agent WebFetch WebSearch; do
    assert_not_contains "$tools" "$bad" "$name tools line" || return 1
  done
}

# ir_numbered_in_order <file> <lead-in>... — item N must open a line as `N. <lead-in>`, and the
# items must appear in ascending line order.
ir_numbered_in_order() {
  local file=$1 i=1 last=0 ln
  shift
  for leadin in "$@"; do
    ln=$(grep -nF -- "$i. $leadin" "$file" | grep "^[0-9]*:$i\. " | head -1 | cut -d: -f1)
    [ -n "$ln" ] || { fail "$(basename "$file"): no line opening with [$i. $leadin]"; return 1; }
    [ "$ln" -gt "$last" ] || { fail "$(basename "$file"): [$i. $leadin] at line $ln is not after line $last"; return 1; }
    last=$ln
    i=$((i + 1))
  done
}

# ir_hard_limits <file> — prints the `## Hard limits` section, lower-cased, up to the next `## `.
ir_hard_limits() {
  awk '/^## Hard limits/ { on = 1; next } on && /^## / { exit } on { print }' "$1" | tr '[:upper:]' '[:lower:]'
}

# ir_claude_md_section — CLAUDE.md between `## Software development` and `## Google integrations`.
ir_claude_md_section() {
  awk '/^## Software development/ { on = 1; next } /^## Google integrations/ { on = 0 } on { print }' "$ROOT_IR/CLAUDE.md"
}

test_ir_ac1_frontmatter() {
  ir_frontmatter_ok "$DIAG_IR" pipeline-diagnostician high || return 1
  ir_frontmatter_ok "$ADJ_IR" pipeline-adjudicator medium || return 1
}

test_ir_ac2_diagnostician_body() {
  local s ln last=0 limits
  assert_file_exists "$DIAG_IR" "diagnostician definition" || return 1
  ir_numbered_in_order "$DIAG_IR" \
    '**Gather evidence before any hypothesis, on both hosts.**' \
    '**Classify before analysing.**' \
    '**Timeline from log lines only.**' \
    '**At least two rival mechanisms.**' \
    '**The mechanism must predict a number.**' \
    '**Attribute upstream.**' \
    '**UNCONFIRMED is a valid result.**' || return 1
  for s in 'environment/host' 'configuration' 'marker protocol' 'supervisor/launcher logic' \
           'agent instructions' 'nondeterministic one-off' \
           'CONFIRMED' 'PARTLY CONFIRMED' 'UNCONFIRMED' \
           'unverified (host unreachable)' \
           'ssh -o BatchMode=yes -o ConnectTimeout=10 clog-exec' \
           'Expected output is never evidence' 'C1'; do
    ir_has "$DIAG_IR" "$s" || return 1
  done
  # Output headings: each on a line of its own (optionally a markdown heading), in this order.
  for s in 'CLASSIFICATION' 'TIMELINE' 'MECHANISMS' 'ROOT CAUSE' 'CLAIMS' 'FALSIFIER'; do
    ln=$(grep -nE "^(#+ )?$s\$" "$DIAG_IR" | head -1 | cut -d: -f1)
    [ -n "$ln" ] || { fail "diagnostician: no output heading line [$s]"; return 1; }
    [ "$ln" -gt "$last" ] || { fail "diagnostician: heading [$s] at line $ln is not after line $last"; return 1; }
    last=$ln
  done
  limits=$(ir_hard_limits "$DIAG_IR")
  [ -n "$limits" ] || { fail "diagnostician: no '## Hard limits' section"; return 1; }
  for s in 'no fix' 'no recommendation' 'must not read' \
           'tee' 'scratch' 'redirect' 'final message'; do
    assert_contains "$limits" "$s" "diagnostician hard limits" || return 1
  done
}

test_ir_ac3_adjudicator_body() {
  local s n limits
  assert_file_exists "$ADJ_IR" "adjudicator definition" || return 1
  ir_numbered_in_order "$ADJ_IR" \
    '**Cite-or-drop.**' \
    '**Recurrence.**' \
    '**Is a change needed?**' \
    '**Judge the fix.**' \
    '**Verdict card.**' \
    '**Record.**' || return 1
  for s in '3 occurrences across ≥2 issues within 14 days' \
           'no pipeline code change' \
           'at most add the missing log line' \
           'Complexity budget: net new mechanisms per fix = 0' \
           'merge or delete one' 'symptom patch' \
           '**[pipeline-adjudicator] NOTE** <signature> — <CHANGE? value>' \
           'gh search issues' 'in:body,comments' '--owner jpmoya --owner Benjis-Plants'; do
    ir_has "$ADJ_IR" "$s" || return 1
  done
  if grep -qF -- 'gh issue create' "$ADJ_IR"; then
    fail "adjudicator: must not contain [gh issue create]"; return 1
  fi
  n=$(grep -oF 'at 1 occurrence' "$ADJ_IR" | wc -l | tr -d ' ')
  [ "$n" -ge 2 ] || { fail "adjudicator: [at 1 occurrence] found $n times, expected >= 2"; return 1; }
  limits=$(ir_hard_limits "$ADJ_IR")
  [ -n "$limits" ] || { fail "adjudicator: no '## Hard limits' section"; return 1; }
  for s in 'only write' 'tee' 'scratch' 'redirect' 'final message'; do
    assert_contains "$limits" "$s" "adjudicator hard limits" || return 1
  done
  assert_not_contains "$limits" 'never post on the incident' "adjudicator hard limits" || return 1
}

test_ir_ac4_verdict_card_byte_for_byte() {
  local card body nl='
'
  assert_file_exists "$ADJ_IR" "adjudicator definition" || return 1
  card=$(cat <<'CARD'
INCIDENT     <repo>#<N> — <what JP saw>, <when>
CLASS        <classification>
CAUSE        CONFIRMED | PARTLY CONFIRMED | UNCONFIRMED — <one or two sentences>
PROOF        <the observed numbers / lines>
CHECK IT     <one command JP can paste>
RIVAL        <the alternative explanation and what ruled it out>
STRUCK       <claims that did not reproduce, or "none">
SEEN BEFORE  <n> times — <refs>
CHANGE?      NO | YES — <class>
FIX          <the minimal fix; net new mechanisms: n>
NOT THE FIX  <the proposed/obvious patch and why it is a symptom patch>   (omit if none)
IF IT WORKS  <a log signature that must stop appearing>
CARD
)
  body=$(cat "$ADJ_IR")
  # Newline-anchored on both sides: the 12 lines must be whole lines, consecutive, in order.
  case "$nl$body$nl" in
    *"$nl$card$nl"*) return 0 ;;
    *) fail "adjudicator: the 12-line verdict card template is not present as one byte-for-byte block"; return 1 ;;
  esac
}

test_ir_ac5_not_wired_into_pipeline() {
  local hits
  hits=$(grep -n 'pipeline-diagnostician\|pipeline-adjudicator' \
    "$ROOT_IR/hooks/pipeline-markers.sh" "$ROOT_IR/agents/orchestrator.md" "$ROOT_IR"/skills/orchestrate/*.sh)
  assert_eq "$hits" "" "incident-review agents referenced in pipeline routing files" || return 1
}

test_ir_ac6_claude_md_paragraph() {
  local section s
  section=$(ir_claude_md_section)
  [ -n "$section" ] || { fail "CLAUDE.md: '## Software development' section not found"; return 1; }
  for s in 'pipeline-diagnostician' 'pipeline-adjudicator' 'verdict card' 'fresh context' \
           'only after JP says yes' 'the orchestrator ban does not apply'; do
    assert_contains "$section" "$s" "CLAUDE.md Software development section" || return 1
  done
}

test_ir_ac7_readmes() {
  local s
  for s in '**Incident review' 'pipeline-diagnostician' 'pipeline-adjudicator' \
           '[pipeline-adjudicator] NOTE' 'verdict-card issue bodies' \
           'CHANGE? NO' 'IF IT WORKS' 'rubber-stamping'; do
    ir_has "$ROOT_IR/README.md" "$s" || return 1
  done
  for s in 'proposal issue' "incident's own issue" 'CHANGE? NO'; do
    ir_has "$ROOT_IR/agents/README.md" "$s" || return 1
  done
  for s in '| pipeline-diagnostician | opus | high |' '| pipeline-adjudicator | opus | medium |'; do
    ir_has "$ROOT_IR/agents/README.md" "$s" || return 1
  done
  grep -qxF '## Incident review (on demand, not a stage)' "$ROOT_IR/agents/README.md" \
    || { fail "agents/README.md: missing heading [## Incident review (on demand, not a stage)]"; return 1; }
}

# Issue #32 AC1. The needle is built from two fragments so this file does not match itself.
test_ir_no_separate_log_issue() {
  local needle="incident led""ger" hits
  hits=$(cd "$ROOT_IR" && grep -rniF -- "$needle" agents/ README.md CLAUDE.md skills/)
  assert_eq "$hits" "" "[$needle] still mentioned" || return 1
}

echo "-- incident review agents (issues #27, #32)"
run_test test_ir_ac1_frontmatter
run_test test_ir_ac2_diagnostician_body
run_test test_ir_ac3_adjudicator_body
run_test test_ir_ac4_verdict_card_byte_for_byte
run_test test_ir_ac5_not_wired_into_pipeline
run_test test_ir_ac6_claude_md_paragraph
run_test test_ir_ac7_readmes
run_test test_ir_no_separate_log_issue
