# Issue #180 — code reviewer rejects Sentry fixes that remove, downgrade or ignore error reporting.
# AC1/AC2: agents/code-reviewer.md carries the checklist block (grep on the ticket's own wording). AC3: the fixture PR diffs
# under fixtures/code-review-sentry/ exist, are mapped to a rule number in the README, and each shows the shape of exactly
# one rule (real-fix.diff: none). AC5: the reviewer's `model` and `tools` front matter is unchanged.
# The rule signatures below are a mechanical reading of rules 1-4 on a diff's added/removed lines, enough to pin what each
# fixture demonstrates; the reviewer itself judges real PRs from the prose rules.

HERE_180=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_180="$HERE_180/../../../agents/code-reviewer.md"
FIX_180="$HERE_180/fixtures/code-review-sentry"

# r180_block — the new checklist block: from its heading to the next checklist heading or section
r180_block() {
  awk '/^\*\*HIGH — silenced error reporting/{on=1; print; next}
       on && (/^\*\*(CRITICAL|HIGH|MEDIUM|LOW) — / || /^## /){exit}
       on{print}' "$AGENT_180"
}
r180_has() { case "$1" in *"$2"*) return 0 ;; *) fail "code-reviewer.md block: missing [$2]"; return 1 ;; esac; }
# r180_rule <block> <n> — the text of numbered rule n (one line)
r180_rule() { printf '%s\n' "$1" | grep -E "^$2\. " | head -1; }

test_r180_ac1_block_has_applicability_condition_and_both_lanes() {
  assert_file_exists "$AGENT_180" "AC1: agents/code-reviewer.md" || return 1
  local b; b=$(r180_block)
  [ -n "$b" ] || { fail "AC1: no '**HIGH — silenced error reporting' block in code-reviewer.md"; return 1; }
  r180_has "$b" "silenced error reporting (Sentry-sourced tickets)" || return 1
  r180_has "$b" 'label `source:sentry`' || return 1
  r180_has "$b" 'line starting `Sentry-Issue:`' || return 1
  r180_has "$b" "both lanes" || return 1
  r180_has "$b" "in non-test code" || return 1
}

test_r180_ac1_block_has_all_five_numbered_rules() {
  local b r; b=$(r180_block)
  r=$(r180_rule "$b" 1)
  r180_has "$r" "removes a capture call" || return 1
  r180_has "$r" '`Sentry.captureException`' || return 1
  r180_has "$r" '`Sentry.captureMessage`' || return 1
  r180_has "$r" '`captureRejectedTechSave`' || return 1
  r180_has "$r" "shared error-capture helper" || return 1
  r180_has "$r" "without replacing it with an equivalent capture on the same failure path" || return 1
  r=$(r180_rule "$b" 2)
  r180_has "$r" 'downgrades a level (`error` or `fatal` to `warning` or `info`)' || return 1
  r180_has "$r" 'lowers `sampleRate`' || return 1
  r=$(r180_rule "$b" 3)
  r180_has "$r" "wraps the failing call in a catch that neither rethrows nor captures" || return 1
  r=$(r180_rule "$b" 4)
  r180_has "$r" '`ignoreErrors`' || return 1
  r180_has "$r" '`denyUrls`' || return 1
  r180_has "$r" '`beforeSend` that returns `null`' || return 1
  r180_has "$r" '`scripts/sentry-intake.config.ts`' || return 1
  r=$(r180_rule "$b" 5)
  r180_has "$r" "deletes or weakens a Sentry guard test" || return 1
  assert_eq "$(printf '%s\n' "$b" | grep -cE '^[0-9]+\. ')" "5" "AC1: exactly five numbered rules in the block" || return 1
}

test_r180_ac2_block_states_high_fail_and_not_a_finding_clause() {
  local b; b=$(r180_block)
  assert_eq "$(printf '%s\n' "$b" | head -1 | grep -c '^\*\*HIGH — silenced error reporting (Sentry-sourced tickets)')" "1" "AC2: the block heading states HIGH" || return 1
  r180_has "$b" "finding at HIGH, verdict FAIL" || return 1
  r180_has "$b" "Making the failing condition not occur (the actual fix) is not a finding" || return 1
  r180_has "$b" '`file:line` of the removed or changed line' || return 1
}

test_r180_ac5_reviewer_front_matter_unchanged() {
  local fm; fm=$(awk 'NR==1&&/^---$/{on=1;next} on&&/^---$/{exit} on{print}' "$AGENT_180")
  assert_eq "$(printf '%s\n' "$fm" | grep '^tools:')" "tools: Bash, Read, Grep, Glob" "AC5: tools front matter unchanged" || return 1
  assert_eq "$(printf '%s\n' "$fm" | grep '^model:')" "model: haiku" "AC5: model front matter unchanged" || return 1
}

# --- fixtures (AC3)
# added / removed content lines of a unified diff (file headers excluded)
r180_added()   { grep -E '^\+' "$1" | grep -vE '^\+\+\+ '; }
r180_removed() { grep -E '^-' "$1" | grep -vE '^--- '; }
R180_CAPTURE='(Sentry\.captureException|Sentry\.captureMessage|captureRejectedTechSave)\('
# one signature per rule, each echoing 1 (the diff shows that rule) or 0
r180_sig1() { r180_removed "$1" | grep -qE "$R180_CAPTURE" && ! r180_added "$1" | grep -qE "$R180_CAPTURE" && echo 1 || echo 0; }
r180_sig2() {
  { r180_removed "$1" | grep -qE "level: *'(error|fatal)'" && r180_added "$1" | grep -qE "level: *'(warning|info)'"; } \
    || { r180_removed "$1" | grep -q 'SampleRate\|sampleRate' && r180_added "$1" | grep -q 'SampleRate\|sampleRate'; } && echo 1 || echo 0
}
r180_sig3() { r180_added "$1" | grep -qE '\bcatch\b' && ! r180_added "$1" | grep -qE "\\bthrow\\b|$R180_CAPTURE" && echo 1 || echo 0; }
r180_sig4() {
  r180_added "$1" | grep -qE 'ignoreErrors|denyUrls|return null' || grep -qE '^\+\+\+ b/scripts/sentry-intake\.config\.ts' "$1" && echo 1 || echo 0
}
r180_sigs() { printf '%s%s%s%s' "$(r180_sig1 "$1")" "$(r180_sig2 "$1")" "$(r180_sig3 "$1")" "$(r180_sig4 "$1")"; }

test_r180_ac3_fixture_directory_has_the_five_diffs() {
  local f
  for f in remove-capture downgrade-level empty-catch ignore-list real-fix; do
    assert_file_exists "$FIX_180/$f.diff" "AC3: fixture $f.diff" || return 1
    grep -qE '^--- a/' "$FIX_180/$f.diff" && grep -qE '^\+\+\+ b/' "$FIX_180/$f.diff" && grep -qE '^@@ -[0-9]+,[0-9]+ \+[0-9]+,[0-9]+ @@' "$FIX_180/$f.diff" \
      || { fail "AC3: $f.diff is not a unified diff (---/+++/@@ headers)"; return 1; }
    grep -E '^\+\+\+ b/' "$FIX_180/$f.diff" | grep -qE '\.(test|spec)\.|__tests__|/tests?/' \
      && { fail "AC3: $f.diff must change non-test code"; return 1; }
  done
  assert_eq "$(ls "$FIX_180"/*.diff | wc -l | tr -d ' ')" "5" "AC3: exactly the five fixture diffs" || return 1
}

test_r180_ac3_readme_maps_each_fixture_to_its_rule_number() {
  local readme="$FIX_180/README.md" line
  assert_file_exists "$readme" "AC3: fixtures README" || return 1
  line=$(grep -F 'remove-capture.diff' "$readme" | head -1);  assert_contains "$line" "rule 1" "AC3: README maps remove-capture.diff" || return 1
  line=$(grep -F 'downgrade-level.diff' "$readme" | head -1); assert_contains "$line" "rule 2" "AC3: README maps downgrade-level.diff" || return 1
  line=$(grep -F 'empty-catch.diff' "$readme" | head -1);     assert_contains "$line" "rule 3" "AC3: README maps empty-catch.diff" || return 1
  line=$(grep -F 'ignore-list.diff' "$readme" | head -1);     assert_contains "$line" "rule 4" "AC3: README maps ignore-list.diff" || return 1
  line=$(grep -F 'real-fix.diff' "$readme" | head -1);        assert_contains "$line" "no rule" "AC3: README maps real-fix.diff to no rule" || return 1
  assert_not_contains "$line" "rule 1" "AC3: real-fix.diff is not mapped to a rule" || return 1
}

test_r180_fixture_each_positive_diff_shows_exactly_one_rule() {
  # signature string = rules 1..4, 1 when the diff shows that rule
  assert_eq "$(r180_sigs "$FIX_180/remove-capture.diff")"  "1000" "remove-capture.diff shows rule 1 only" || return 1
  assert_eq "$(r180_sigs "$FIX_180/downgrade-level.diff")" "0100" "downgrade-level.diff shows rule 2 only" || return 1
  assert_eq "$(r180_sigs "$FIX_180/empty-catch.diff")"     "0010" "empty-catch.diff shows rule 3 only" || return 1
  assert_eq "$(r180_sigs "$FIX_180/ignore-list.diff")"     "0001" "ignore-list.diff shows rule 4 only" || return 1
}

test_r180_fixture_real_fix_shows_no_rule_and_keeps_the_capture() {
  local f="$FIX_180/real-fix.diff"
  assert_eq "$(r180_sigs "$f")" "0000" "real-fix.diff is described by no rule" || return 1
  # the capture call is retained (an unchanged context line) and the fix adds a guard before the failing call
  grep -E '^ ' "$f" | grep -qE "$R180_CAPTURE" || { fail "real-fix.diff: the capture call must be retained as an unchanged line"; return 1; }
  r180_added "$f" | grep -qE '\bif \(' || { fail "real-fix.diff: expected an added guard (null check) before the failing call"; return 1; }
  assert_eq "$(r180_removed "$f" | grep -c .)" "0" "real-fix.diff removes nothing" || return 1
}

run_test test_r180_ac1_block_has_applicability_condition_and_both_lanes
run_test test_r180_ac1_block_has_all_five_numbered_rules
run_test test_r180_ac2_block_states_high_fail_and_not_a_finding_clause
run_test test_r180_ac5_reviewer_front_matter_unchanged
run_test test_r180_ac3_fixture_directory_has_the_five_diffs
run_test test_r180_ac3_readme_maps_each_fixture_to_its_rule_number
run_test test_r180_fixture_each_positive_diff_shows_exactly_one_rule
run_test test_r180_fixture_real_fix_shows_no_rule_and_keeps_the_capture
