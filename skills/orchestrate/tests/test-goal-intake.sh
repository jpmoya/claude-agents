# #321 — goal-intake skill: requirements-record verifier (check.sh), SKILL.md doc contract, `deliver.sh register`
# --mockups/--requirements, and error capture.
# Sourced by run-tests.sh AFTER test-goal-deliver.sh (reuses its dg_* sandbox, stateful fake gh and fixtures).
# Interface pinned here (ticket gives fixtures, not argv): `check.sh <owner/repo#N>` — N is the issue named by the
# registry `requirements` field. Exit 0 = go-check would pass; exit 1 = refusal, reason on stderr/stdout.
# The `deliver.sh register --title … --repos … --requirements … --mockups …` tests need #319's v2 parser/label goals
# (ticket: "with #319's parser"); they are red on main until #319 lands and the branch is rebased.
# Expected values come from the ticket text or hand arithmetic in comments — never from the code.

GI_DIR=$(cd "$DG_SKILL/../goal-intake" 2>/dev/null && pwd || echo "$DG_SKILL/../goal-intake")
GI_RK=example-owner_project-a
GI_BIRK=example-owner_Business-Intelligence

# gi_issue <owner_repo_key> <n> <open|closed> <body> — fixture issue with a given body
gi_issue() {
  mkdir -p "$DG_ST/issues/$1"
  dg_issue "$1" "$2" "$3"
  local f="$DG_ST/issues/$1/$2.json"
  jq -c --arg b "$4" '.body = $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# gi_check <owner/repo#N> — runs check.sh in the sandbox. Sets DG_RC / DG_OUT / DG_ERR.
gi_check() {
  local errf="$DG_HOME/stderr.txt"
  DG_OUT=$(cd "$DG_CWD" && env HOME="$DG_HOME" PIPE="$DG_PIPE" LOGDIR="$DG_HOME/logs/pipeline" DG_HOST="$DG_HOST" \
    PATH="$DG_BIN:$PATH" bash "$GI_DIR/check.sh" "$@" 2>"$errf" </dev/null); DG_RC=$?
  DG_ERR=$(cat "$errf")
}

# ------------------------------------------------------------------ AC1: check.sh fixtures 1-4 ----------------

# Fixture 1: valid requirements issue → exit 0. Hand arithmetic: section has 2 non-empty lines.
test_gi_check_valid_requirements_exits_0() {
  dg_setup
  gi_issue $GI_RK 50 open $'Goal: Quote intake\n\n## Requirements\n- Customers can upload photos\n- Staff get an email\n\n## Notes\nx'
  gi_check example-owner/project-a#50
  local rc=0
  assert_eq "$DG_RC" "0" "fixture 1: valid record exits 0 (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

# A closed requirements issue is still a valid record (#319: "open or closed and non-empty").
test_gi_check_closed_issue_with_requirements_exits_0() {
  dg_setup
  gi_issue $GI_RK 51 closed $'## Requirements\nOne agreed line'
  gi_check example-owner/project-a#51
  local rc=0
  assert_eq "$DG_RC" "0" "closed issue with a Requirements section exits 0 (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

# Fixture 2: no `## Requirements` section → exit 1, message names why (missing section).
test_gi_check_missing_section_exits_1_naming_why() {
  dg_setup
  gi_issue $GI_RK 52 open $'Goal: Quote intake\n\n## Notes\nSome text but no requirements heading'
  gi_check example-owner/project-a#52
  local rc=0 all="$DG_OUT$DG_ERR"
  assert_eq "$DG_RC" "1" "fixture 2: missing section exits 1" || rc=1
  assert_contains "$all" "## Requirements" "fixture 2: message names the section" || rc=1
  assert_contains "$all" "missing" "fixture 2: message says it is missing" || rc=1
  dg_teardown; return $rc
}

# Fixture 3: heading present, section empty → exit 1 naming "empty".
test_gi_check_empty_section_exits_1_naming_why() {
  dg_setup
  gi_issue $GI_RK 53 open $'## Requirements\n\n## Notes\nText'
  gi_check example-owner/project-a#53
  local rc=0 all="$DG_OUT$DG_ERR"
  assert_eq "$DG_RC" "1" "fixture 3: empty section exits 1" || rc=1
  assert_contains "$all" "empty" "fixture 3: message says the section is empty" || rc=1
  dg_teardown; return $rc
}

# Boundary: whitespace-only lines are empty (ticket: "at least one non-empty line"); text in a LATER section does
# not count, and a section that is last in the body with only blank lines is empty too.
test_gi_check_whitespace_only_section_is_empty() {
  dg_setup
  gi_issue $GI_RK 54 open $'## Requirements\n   \n\t\n## Notes\nText that belongs to Notes'
  gi_check example-owner/project-a#54
  local rc=0
  assert_eq "$DG_RC" "1" "whitespace-only section before another heading exits 1" || rc=1
  assert_contains "$DG_OUT$DG_ERR" "empty" "…naming empty" || rc=1
  gi_issue $GI_RK 55 open $'Goal: x\n\n## Requirements\n\n   \n'
  gi_check example-owner/project-a#55
  assert_eq "$DG_RC" "1" "blank trailing section at end of body exits 1" || rc=1
  dg_teardown; return $rc
}

# Boundary: exactly one non-empty line is enough (off-by-one on "at least one").
test_gi_check_single_line_section_exits_0() {
  dg_setup
  gi_issue $GI_RK 56 open $'## Requirements\nJust one line'
  gi_check example-owner/project-a#56
  local rc=0
  assert_eq "$DG_RC" "0" "one non-empty line exits 0 (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

# Issue that does not exist → exit 1 (fail closed), says it cannot be read/found.
test_gi_check_nonexistent_issue_exits_1() {
  dg_setup
  gi_check example-owner/project-a#4040
  local rc=0
  assert_eq "$DG_RC" "1" "unreadable issue exits 1" || rc=1
  assert_ne "$DG_OUT$DG_ERR" "" "a reason is printed" || rc=1
  dg_teardown; return $rc
}

# Fixture 4: repo = Business-Intelligence → exit 1 even though the record itself is valid.
test_gi_check_business_intelligence_exits_1() {
  dg_setup
  gi_issue $GI_BIRK 60 open $'## Requirements\n- Valid text'
  gi_check example-owner/Business-Intelligence#60
  local rc=0
  assert_eq "$DG_RC" "1" "fixture 4: Business-Intelligence exits 1" || rc=1
  assert_contains "$DG_OUT$DG_ERR" "Business-Intelligence" "fixture 4: message names the excluded repo" || rc=1
  dg_teardown; return $rc
}

# ------------------------------------------------------------------ AC2: SKILL.md grep + frontmatter ----------

test_gi_skill_frontmatter_valid_like_siblings() {
  local f="$GI_DIR/SKILL.md" rc=0 fm
  assert_file_exists "$f" "SKILL.md exists" || return 1
  assert_eq "$(sed -n 1p "$f")" "---" "line 1 opens frontmatter" || rc=1
  fm=$(awk 'NR==1{next} /^---$/{exit} {print}' "$f")
  assert_ne "$(awk 'NR>1 && /^---$/{print "closed"; exit}' "$f")" "" "frontmatter is closed by ---" || rc=1
  assert_contains "$fm" "name: goal-intake" "frontmatter name equals the directory name" || rc=1
  printf '%s\n' "$fm" | grep -Eq '^description: *[^ ]' || { fail "frontmatter has a non-empty description"; rc=1; }
  return $rc
}

test_gi_skill_contains_explicit_mockups_question() {
  local f="$GI_DIR/SKILL.md"
  assert_file_exists "$f" "SKILL.md exists" || return 1
  grep -qF 'Do you want to review mockups for this goal, or skip them?' "$f" \
    || { fail "SKILL.md lacks the exact mockups question"; return 1; }
  grep -qE 'mockups: *review\|skip|mockups.*review.*skip' "$f" || { fail "SKILL.md must record the answer as mockups: review|skip"; return 1; }
}

test_gi_skill_dispatches_product_manager_never_hand_writes() {
  local f="$GI_DIR/SKILL.md"
  assert_file_exists "$f" "SKILL.md exists" || return 1
  grep -q 'product-manager' "$f" || { fail "SKILL.md lacks the product-manager dispatch step"; return 1; }
  grep -qiE 'never hand-write' "$f" || { fail "SKILL.md must say never hand-write tickets"; return 1; }
  grep -qF '## Requirements' "$f" || { fail "SKILL.md must name the '## Requirements' record section"; return 1; }
}

test_gi_skill_calls_deliver_register_with_flags() {
  local f="$GI_DIR/SKILL.md"
  assert_file_exists "$f" "SKILL.md exists" || return 1
  grep -q 'deliver.sh register' "$f" || { fail "SKILL.md lacks the deliver.sh register call"; return 1; }
  grep -q -- '--requirements' "$f" || { fail "SKILL.md register call lacks --requirements"; return 1; }
  grep -q -- '--mockups' "$f" || { fail "SKILL.md register call lacks --mockups"; return 1; }
  grep -q 'check.sh' "$f" || { fail "SKILL.md must reference check.sh"; return 1; }
}

test_gi_skill_excludes_business_intelligence_and_brainstorms() {
  local f="$GI_DIR/SKILL.md"
  assert_file_exists "$f" "SKILL.md exists" || return 1
  grep -q 'Business-Intelligence' "$f" || { fail "SKILL.md lacks the Business-Intelligence exclusion"; return 1; }
  grep -qi 'refus' "$f" || { fail "SKILL.md must say the skill refuses BI repos"; return 1; }
  grep -qi 'brainstorming' "$f" || { fail "SKILL.md must apply the brainstorming skill"; return 1; }
  grep -qiE 'never (run )?headless|interactive' "$f" || { fail "SKILL.md must state it is interactive / never headless"; return 1; }
}

# ------------------------------------------------------------------ AC3: deliver.sh register --mockups --------

# gi_register <mockups-args…> — registers a 1-repo label goal seeded by project-a#7 (open ticket from the fixture).
gi_register() {
  gi_issue $GI_RK 7 open $'Goal: Photo intake\n\n## Requirements\n- agreed'
  dg_run register --title "Photo intake" --repos example-owner/project-a --requirements example-owner/project-a#7 "$@"
}

# gi_block_for_title — the registry block of the only delivery-goal issue
gi_block() { local f; f=$(dg_reg_files | head -1); [ -n "$f" ] && dg_block "$f"; }

test_gi_register_stores_mockups_skip_in_v2_block() {
  dg_setup
  gi_register --mockups skip
  local rc=0 blk
  assert_eq "$DG_RC" "0" "register --mockups skip exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "one registry issue created" || rc=1
  blk=$(gi_block)
  assert_eq "$(printf '%s' "$blk" | jq -r .v 2>/dev/null)" "2" "block is registry v2" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .mockups 2>/dev/null)" "skip" "mockups stored as skip" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .requirements 2>/dev/null)" "example-owner/project-a#7" "requirements stored" || rc=1
  dg_teardown; return $rc
}

test_gi_register_stores_mockups_review() {
  dg_setup
  gi_register --mockups review
  local rc=0
  assert_eq "$DG_RC" "0" "register --mockups review exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gi_block | jq -r .mockups 2>/dev/null)" "review" "mockups stored as review" || rc=1
  dg_teardown; return $rc
}

# #319: "`mockups` defaults to `review`" — the skill relies on this default when JP gives no explicit answer.
test_gi_register_defaults_mockups_to_review() {
  dg_setup
  gi_register
  local rc=0
  assert_eq "$DG_RC" "0" "register without --mockups exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gi_block | jq -r .mockups 2>/dev/null)" "review" "default is review" || rc=1
  dg_teardown; return $rc
}

# Anything other than review|skip is refused, naming the flag, and no registry issue is written.
test_gi_register_rejects_invalid_mockups_value() {
  dg_setup
  gi_register --mockups maybe
  local rc=0
  assert_ne "$DG_RC" "0" "invalid --mockups is refused" || rc=1
  assert_contains "$DG_ERR" "mockups" "message names --mockups" || rc=1
  assert_contains "$DG_ERR" "review" "message lists the allowed values" || rc=1
  assert_eq "$(dg_reg_count)" "0" "no registry issue written" || rc=1
  dg_teardown; return $rc
}

# ------------------------------------------------------------------ AC5: observability -------------------------

# An unreadable requirements issue (gh fails) on the check.sh path is captured: exit 1 AND an error row/line with
# release = checkout commit SHA (7 chars), host and a route tag; no token/instruction text. Accepts the existing
# goal_err form ([goal] error line in supervisor.log) or a pipeline_event `error` row in events.jsonl.
test_gi_check_gh_failure_is_captured_with_release_host_route() {
  dg_setup
  mv "$DG_BIN/gh" "$DG_BIN/gh.real"
  printf '#!/bin/bash\necho "gh: boom GI-CANARY-TOKEN-ghp_x" >&2\nexit 1\n' > "$DG_BIN/gh"; chmod +x "$DG_BIN/gh"
  gi_check example-owner/project-a#50
  local rc=0 sha slog events row line
  sha=$(git -C "$DG_SKILL" rev-parse HEAD | cut -c1-7)
  slog=$(cat "$DG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  events="$DG_HOME/logs/pipeline/events.jsonl"
  row=$(jq -c 'select(.event == "error")' "$events" 2>/dev/null | head -1)
  line=$(printf '%s\n' "$slog" | grep -F '[goal] error' | head -1)
  assert_eq "$DG_RC" "1" "gh failure exits 1" || rc=1
  if [ -n "$row" ]; then
    assert_eq "$(printf '%s' "$row" | jq -r '.release' | cut -c1-7)" "$sha" "error row release = checkout SHA" || rc=1
    assert_ne "$(printf '%s' "$row" | jq -r '.host // ""')" "" "error row has host" || rc=1
    assert_ne "$(printf '%s' "$row" | jq -r '.route // ""')" "" "error row has route tag" || rc=1
  elif [ -n "$line" ]; then
    assert_contains "$line" "release=$sha" "goal_err line carries release=<SHA>" || rc=1
    assert_contains "$line" "host=" "goal_err line carries host" || rc=1
  else
    fail "no error row in events.jsonl and no '[goal] error' line in supervisor.log"; rc=1
  fi
  assert_not_contains "$slog$(cat "$events" 2>/dev/null)" "GI-CANARY-TOKEN" "no gh stderr/secrets in the event" || rc=1
  dg_teardown; return $rc
}

run_test test_gi_check_valid_requirements_exits_0
run_test test_gi_check_closed_issue_with_requirements_exits_0
run_test test_gi_check_missing_section_exits_1_naming_why
run_test test_gi_check_empty_section_exits_1_naming_why
run_test test_gi_check_whitespace_only_section_is_empty
run_test test_gi_check_single_line_section_exits_0
run_test test_gi_check_nonexistent_issue_exits_1
run_test test_gi_check_business_intelligence_exits_1
run_test test_gi_skill_frontmatter_valid_like_siblings
run_test test_gi_skill_contains_explicit_mockups_question
run_test test_gi_skill_dispatches_product_manager_never_hand_writes
run_test test_gi_skill_calls_deliver_register_with_flags
run_test test_gi_skill_excludes_business_intelligence_and_brainstorms
run_test test_gi_register_stores_mockups_skip_in_v2_block
run_test test_gi_register_stores_mockups_review
run_test test_gi_register_defaults_mockups_to_review
run_test test_gi_register_rejects_invalid_mockups_value
run_test test_gi_check_gh_failure_is_captured_with_release_host_route
