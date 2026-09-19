# Issue #29 AC14 — the three docs state the new publication rule: the issue title and GitHub issue
# URL are published on the public status page; STATUS_REPO_ALIASES still populates runs[].repo in
# the payload and /status.json but is no longer shown in the HTML table; and the old "Repo names
# never leave the host" sentence is gone. (test-ac18-docs.sh still owns "docs mention
# STATUS_REPO_ALIASES" and stays green untouched.)
#
# Each doc is scoped to its own status-board text so an unrelated mention elsewhere in the file
# cannot satisfy the check.

HERE_TD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_TD=$(cd "$HERE_TD/../../.." && pwd)

# td_readme_section — the README.md "Status board" paragraph (one line).
td_readme_section() { grep -E '^\*\*Status board' "$ROOT_TD/README.md" 2>/dev/null; }

# td_skill_section — SKILL.md from "## Status board" up to (excluding) the next "## " heading.
td_skill_section() {
  awk '/^## Status board/{on=1; print; next} on && /^## /{on=0} on' "$HERE_TD/../SKILL.md" 2>/dev/null
}

# td_worker_readme — the whole status-page/README.md (it has no status-board-specific section).
td_worker_readme() { cat "$ROOT_TD/status-page/README.md" 2>/dev/null; }

# td_check_publication_rule <label> <text> — asserts the AC14 statements on <text>.
td_check_publication_rule() {
  local label=$1 text=$2
  assert_ne "$text" "" "AC14: $label — status-board text must be found (scoping sanity)" || return 1
  printf '%s' "$text" | grep -qi 'issue title' \
    || { fail "AC14: $label must say the issue title is published"; return 1; }
  printf '%s' "$text" | grep -qiE 'issue URL' \
    || { fail "AC14: $label must say the GitHub issue URL is published"; return 1; }
  printf '%s' "$text" | grep -qi 'public' \
    || { fail "AC14: $label must say this is on the public status page"; return 1; }
  printf '%s' "$text" | grep -q 'STATUS_REPO_ALIASES' \
    || { fail "AC14: $label must still mention STATUS_REPO_ALIASES"; return 1; }
  printf '%s' "$text" | grep -qF 'runs[].repo' \
    || { fail "AC14: $label must say STATUS_REPO_ALIASES still populates runs[].repo"; return 1; }
  printf '%s' "$text" | grep -qi 'no longer' \
    || { fail "AC14: $label must say the alias is no longer shown in the HTML table ('no longer')"; return 1; }
  printf '%s' "$text" | grep -qi 'HTML' \
    || { fail "AC14: $label must say the alias is no longer shown in the HTML table ('HTML')"; return 1; }
}

test_ac14_readme_states_publication_rule() {
  td_check_publication_rule "README.md status board paragraph" "$(td_readme_section)"
}

test_ac14_skill_md_states_publication_rule() {
  td_check_publication_rule "SKILL.md Status board section" "$(td_skill_section)"
}

test_ac14_worker_readme_states_publication_rule() {
  td_check_publication_rule "status-page/README.md" "$(td_worker_readme)"
}

test_ac14_old_privacy_sentence_removed() {
  local n_readme n_skill
  n_readme=$(grep -c "Repo names never leave the host" "$ROOT_TD/README.md" 2>/dev/null | tr -d ' ')
  n_skill=$(grep -c "Repo names never leave the host" "$HERE_TD/../SKILL.md" 2>/dev/null | tr -d ' ')
  assert_eq "$n_readme" "0" "AC14: README.md must no longer say \"Repo names never leave the host\"" || return 1
  assert_eq "$n_skill" "0" "AC14: SKILL.md must no longer say \"Repo names never leave the host\"" || return 1
}

run_test test_ac14_readme_states_publication_rule
run_test test_ac14_skill_md_states_publication_rule
run_test test_ac14_worker_readme_states_publication_rule
run_test test_ac14_old_privacy_sentence_removed
