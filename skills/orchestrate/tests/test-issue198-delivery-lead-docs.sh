# Issue #198 — goal-bound delivery lead docs: CLAUDE.md, agents/project-manager.md, SKILL.md, README.md
# (deliver.sh section + relauncher migration checklist). Docs-only; pinned by literal strings read from
# tracked files. No gh, no network, no /tmp/pipeline.
# AC4's "full suite green" is the run-tests.sh run itself; the #109 one-cycle-per-launch rule is re-pinned
# here independently of the (to be updated) keyword assertions in test-pm-headless-pacing-docs.sh.

HERE_198=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_198=$(cd "$HERE_198/../../.." && pwd)
CLAUDE_198="$ROOT_198/CLAUDE.md"
PM_198="$ROOT_198/agents/project-manager.md"
SKILL_198="$ROOT_198/skills/orchestrate/SKILL.md"
README_198="$ROOT_198/README.md"

d198_has()   { grep -qF  -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
d198_hasnt() { if grep -qF -- "$2" "$1"; then fail "$(basename "$1"): must not contain [$2]"; return 1; fi; }
d198_has_i() { grep -qiE -- "$2" "$1" || { fail "$(basename "$1"): missing (regex, any case) [$2]"; return 1; }; }

# d198_para <file> — the "Project manager (delivery lead)" paragraph of CLAUDE.md
d198_para() { grep -F '**Project manager (delivery lead).**' "$1"; }
# d198_section <file> <heading-regex> — body of the first "## " section whose heading matches
d198_section() {
  awk -v re="$2" '/^## /{ if (on) exit; if ($0 ~ re) { on=1; next } } on' "$1"
}
# d198_items <text> — one list item (incl. continuation lines) per output line, joined with spaces
d198_items() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { if (cur != "") print cur; cur=$0; next }
    /^[[:space:]]*$/ { if (cur != "") print cur; cur=""; next }
    { if (cur != "") cur = cur " " $0 }
    END { if (cur != "") print cur }'
}

# d198_sentences <text> — one sentence per line: lines are joined into blocks (blank line or a new list item
# starts a block), then every ". " ends a sentence. Used so two terms must sit in the SAME sentence.
d198_sentences() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { if (cur != "") print cur; cur=$0; next }
    /^[[:space:]]*$/ { if (cur != "") print cur; cur=""; next }
    { cur = (cur == "") ? $0 : cur " " $0 }
    END { if (cur != "") print cur }' | sed -e 's/\. /.\
/g'
}
# d198_sentence_with <text> <regex>... — sentences matching every regex (case-insensitive, ERE)
d198_sentence_with() {
  local out re; out=$(d198_sentences "$1"); shift
  for re in "$@"; do out=$(printf '%s\n' "$out" | grep -iE -- "$re" || true); done
  printf '%s\n' "$out" | grep . || true
}

# ---- AC1 ---------------------------------------------------------------------------------------
test_198_ac1_no_launcher_yet_anywhere() {
  local lit hits
  lit="no launcher"" yet"   # split so this file does not match itself
  hits=$(cd "$ROOT_198" && grep -rnF -- "$lit" CLAUDE.md agents skills README.md 2>/dev/null \
         | grep -v 'skills/orchestrate/tests/test-issue198-' || true)
  assert_eq "$hits" "" "AC1: [$lit] must not remain anywhere"
}
test_198_ac1_readme_no_launcher_for_pm_yet() {
  # README's older wording of the same claim: "There is no launcher for the project-manager yet"
  if grep -qiE 'no launcher for the project-manager yet|JP starts it by hand with a brief' "$README_198"; then
    fail "README.md still says the project-manager has no launcher / JP starts it by hand"; return 1
  fi
}

# ---- AC2: CLAUDE.md ----------------------------------------------------------------------------
test_198_ac2_claude_md_names_deliver_sh() {
  local p; p=$(d198_para "$CLAUDE_198")
  assert_ne "$p" "" "delivery-lead paragraph exists" || return 1
  assert_contains "$p" 'skills/orchestrate/deliver.sh' "AC2: full deliver.sh path" || return 1
  assert_contains "$p" 'supervisor keeps' "AC2: 'supervisor keeps' (it alive)" || return 1
}
test_198_ac2_claude_md_supervisor_stops_at_completion() {
  local p hit; p=$(d198_para "$CLAUDE_198")
  # one sentence: the supervisor ... stops ... at completion
  hit=$(d198_sentence_with "$p" '(^|[^a-z])supervisor([^a-z]|$)' 'stops?([^a-z]|$)' 'complet')
  assert_ne "$hit" "" "CLAUDE.md: one sentence must say the supervisor stops the lead at completion" || return 1
  # one sentence: dispatched via deliver.sh and bound to a goal
  hit=$(d198_sentence_with "$p" 'skills/orchestrate/deliver\.sh' '(^|[^a-z])goal([^a-z]|$)')
  assert_ne "$hit" "" "CLAUDE.md: one sentence must say it is dispatched with deliver.sh bound to a goal"
}
test_198_ac2_claude_md_agents_never_create_relaunchers() {
  local p hit; p=$(d198_para "$CLAUDE_198")
  # one sentence: negation, then launchd/cron/loop, then relaunchers; and launchd and cron both named in it
  hit=$(d198_sentence_with "$p" '(never|do not|must not)[^.]*(launchd|cron|loop)[^.]*relaunch' 'launchd' 'cron')
  assert_ne "$hit" "" "CLAUDE.md: one sentence must say agents never create launchd/cron/loop relaunchers"
}
test_198_claude_md_no_stale_start_by_brief() {
  local p; p=$(d198_para "$CLAUDE_198")
  assert_not_contains "$p" 'JP starts it with a brief' "stale hand-start sentence removed"
}

# ---- AC2: agents/project-manager.md ------------------------------------------------------------
test_198_ac2_pm_md_never_unload() {
  d198_has "$PM_198" 'never unload' || return 1
  grep -iE 'never unload' "$PM_198" | grep -qiE 'job|launchd|cron|relaunch|goal' \
    || { fail "project-manager.md: 'never unload' must name what is not unloaded (jobs/launchd/cron)"; return 1; }
}
test_198_ac2_pm_md_completion_decided_by_machinery() {
  d198_has_i "$PM_198" 'completion is decided by the (machinery|supervisor)' || return 1
}
test_198_ac2_pm_md_no_pm_cycle_sh() {
  d198_hasnt "$PM_198" 'pm-cycle.sh' || return 1
  d198_hasnt "$PM_198" 'a cron entry or relaunch loop' || return 1
}
test_198_pm_md_supervisor_sets_pace_in_sections_3_4() {
  local sec; sec=$(awk '/^## 3\./{on=1} /^## 5\./{on=0} on' "$PM_198" | sed -e 's/\. /.\
/g')
  printf '%s\n' "$sec" | grep -iE 'supervisor' | grep -iE 'pac(e|es|ing)|cadence|interval' | grep -qi . \
    || { fail "§3/§4: a sentence must say the supervisor (not the agent) sets the pace"; return 1; }
  printf '%s\n' "$sec" | grep -iE 'launcher|relaunch loop|cron entry' | grep -iE 'sets the pace' | grep -q . \
    && { fail "§3/§4: the launcher/cron-sets-the-pace sentence must be gone"; return 1; }
  return 0
}
test_198_pm_md_one_cycle_per_launch_still_pinned() {  # AC4 / #109
  local sec; sec=$(awk '/^## 3\./{on=1} /^## 5\./{on=0} on' "$PM_198" | sed -e 's/\. /.\
/g')
  printf '%s\n' "$sec" | grep -iw headless | grep -iE 'one (loop )?cycle per launch' | grep -q . \
    || { fail "§3/§4 must still say a headless run does one cycle per launch"; return 1; }
}
test_198_pm_md_jp_only_parks_and_waiting_on_jp() {
  d198_has "$PM_198" 'waiting on JP' || return 1
  grep -iE 'JP-only' "$PM_198" | grep -qiE 'park' || { fail "project-manager.md: JP-only items must park the ticket"; return 1; }
}

# ---- item 3: deliver.sh sections ---------------------------------------------------------------
d198_check_deliver_section() {  # <file> <label>
  local s hit
  s=$(d198_section "$1" 'deliver[.]sh')
  assert_ne "$s" "" "$2: a '## ' section whose heading names deliver.sh" || return 1
  local tok
  for tok in 'owner/repo:milestone:' 'owner/repo:milestones:all' 'owner/repo#N' 'status' 'stop' 'resume' '--here' 'skills/orchestrate/deliver.sh'; do
    assert_contains "$s" "$tok" "$2: deliver.sh section mentions [$tok]" || return 1
  done
  # whole words, same sentence: overlap refusal ... live (the conflicting goal); host ... pin
  hit=$(d198_sentence_with "$s" '(^|[^a-z])overlap' '(^|[^a-z])live([^a-z]|$)')
  assert_ne "$hit" "" "$2: one sentence must say the overlap refusal names the live conflicting goal" || return 1
  hit=$(d198_sentence_with "$s" '(^|[^a-z])host([^a-z]|$)' '(^|[^a-z])(pin|pins|pinned)([^a-z]|$)')
  assert_ne "$hit" "" "$2: one sentence must document the host pin"
}
test_198_skill_md_has_deliver_section() { d198_check_deliver_section "$SKILL_198" "SKILL.md"; }
test_198_readme_has_deliver_section()   { d198_check_deliver_section "$README_198" "README.md"; }
test_198_docs_do_not_invent_skills_deliver_path() {
  local f
  for f in "$CLAUDE_198" "$PM_198" "$SKILL_198" "$README_198"; do
    d198_hasnt "$f" 'skills/deliver/' || return 1
  done
}

# ---- AC3: README migration checklist -----------------------------------------------------------
d198_migration_items() {
  d198_items "$(d198_section "$README_198" '[Mm]igrat')"
}
test_198_ac3_migration_section_exists() {
  assert_ne "$(d198_section "$README_198" '[Mm]igrat')" "" "README.md: a '## ' migration section exists"
}
# The four relauncher names; each must have its OWN list item that names no other relauncher.
D198_RE_PMCD='com\.jp\.pm-cd'
D198_RE_SALES='sales-3\.1\.1'
D198_RE_RT='refactor-tracker/pm-cycle\.sh'
D198_RE_PML='pm-logging/pm-log-cycle\.sh'
# d198_check_relauncher <label> <own-regex> <verify-regex> <other-regex>...
d198_check_relauncher() {
  local label="$1" own="$2" ver="$3" items hit line after o; shift 3
  items=$(d198_migration_items)
  hit=$(printf '%s\n' "$items" | grep -E -- "$own" || true)
  assert_ne "$hit" "" "AC3: a checklist item names $label" || return 1
  for o in "$@"; do
    if printf '%s\n' "$hit" | grep -qE -- "$o"; then
      fail "AC3: the $label item also names another relauncher [$o]; one item per relauncher"; return 1
    fi
  done
  printf '%s\n' "$hit" | grep -qF 'deliver.sh' || { fail "AC3: $label item must name the replacing goal via deliver.sh"; return 1; }
  # the verification command must come after the word Verify inside this item
  after=$(printf '%s\n' "$hit" | awk '{ i = index(tolower($0), "verif"); if (i) print substr($0, i) }')
  assert_ne "$after" "" "AC3: $label item must have a verification line ('Verify')" || return 1
  printf '%s\n' "$after" | grep -qE -- "$ver" || { fail "AC3: $label item's verification (after 'Verify') must use [$ver]"; return 1; }
}
test_198_ac3_pm_cd_launchd() {
  d198_check_relauncher 'Mac launchd com.jp.pm-cd' "$D198_RE_PMCD" 'launchctl list \| grep pm-cd' "$D198_RE_SALES" "$D198_RE_RT" "$D198_RE_PML" || return 1
  local s; s=$(d198_section "$README_198" '[Mm]igrat')
  assert_contains "$s" 'launchctl bootout' "AC3: bootout step" || return 1
  assert_contains "$s" 'pm-cd-relaunch.sh' "AC3: ~/logs/pipeline/pm-cd-relaunch.sh named" || return 1
  assert_contains "$s" '~/logs/pipeline/pm-cd-relaunch.sh' "AC3: full path of the relaunch script" || return 1
  printf '%s\n' "$s" | grep -qiE 'plist' || { fail "AC3: delete the plist"; return 1; }
}
test_198_ac3_sales_cycle_sh() {
  d198_check_relauncher 'Mac sales-3.1.1 cycle.sh' "$D198_RE_SALES" 'deliver\.sh status' "$D198_RE_PMCD" "$D198_RE_RT" "$D198_RE_PML" || return 1
  printf '%s\n' "$(d198_migration_items)" | grep -F 'sales-3.1.1' | grep -qF 'cycle.sh' \
    || { fail "AC3: sales-3.1.1 item must name cycle.sh"; return 1; }
}
test_198_ac3_vm_refactor_tracker_pm_cycle() {
  d198_check_relauncher 'VM cron refactor-tracker/pm-cycle.sh' "$D198_RE_RT" 'crontab -l \| grep pm-' "$D198_RE_PMCD" "$D198_RE_SALES" "$D198_RE_PML" || return 1
}
test_198_ac3_vm_pm_logging_pm_log_cycle() {
  d198_check_relauncher 'VM cron pm-logging/pm-log-cycle.sh' "$D198_RE_PML" 'crontab -l \| grep pm-' "$D198_RE_PMCD" "$D198_RE_SALES" "$D198_RE_RT" || return 1
}
test_198_ac3_checklist_has_deliver_status_verification() {
  local s; s=$(d198_section "$README_198" '[Mm]igrat')
  assert_contains "$s" 'deliver.sh status' "AC3: deliver.sh status shows the goal" || return 1
  assert_contains "$s" 'launchctl list | grep pm-cd' "AC3: launchctl verification" || return 1
  assert_contains "$s" 'crontab -l | grep pm-' "AC3: crontab verification" || return 1
}

for t in \
  test_198_ac1_no_launcher_yet_anywhere test_198_ac1_readme_no_launcher_for_pm_yet \
  test_198_ac2_claude_md_names_deliver_sh test_198_ac2_claude_md_supervisor_stops_at_completion \
  test_198_ac2_claude_md_agents_never_create_relaunchers test_198_claude_md_no_stale_start_by_brief \
  test_198_ac2_pm_md_never_unload test_198_ac2_pm_md_completion_decided_by_machinery \
  test_198_ac2_pm_md_no_pm_cycle_sh test_198_pm_md_supervisor_sets_pace_in_sections_3_4 \
  test_198_pm_md_one_cycle_per_launch_still_pinned test_198_pm_md_jp_only_parks_and_waiting_on_jp \
  test_198_skill_md_has_deliver_section test_198_readme_has_deliver_section \
  test_198_docs_do_not_invent_skills_deliver_path \
  test_198_ac3_migration_section_exists test_198_ac3_pm_cd_launchd test_198_ac3_sales_cycle_sh \
  test_198_ac3_vm_refactor_tracker_pm_cycle test_198_ac3_vm_pm_logging_pm_log_cycle \
  test_198_ac3_checklist_has_deliver_status_verification
do run_test "$t"; done
