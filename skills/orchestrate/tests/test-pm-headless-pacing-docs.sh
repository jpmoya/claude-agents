# Issue #109 — project-manager.md §3/§4: a headless (-p) run does ONE loop cycle per launch; pacing belongs
# to the launcher; ScheduleWakeup / background sleep / keep-alive watchers are forbidden as headless pacing;
# /loop self-pacing is interactive-only; the 20–30 min cadence is the launcher's interval.
# The checker is run against the real file AND against hand-written pre-fix / fixed fixtures (self-check).
ROOT_PM=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PM_MD="$ROOT_PM/agents/project-manager.md"

# pm_sections <file> — §3 and §4 (from "## 3." up to "## 5."), one sentence per line.
pm_sections() {
  awk '/^## 3\./{on=1} /^## 5\./{on=0} on' "$1" | sed -e 's/\. /.\
/g'
}
# Negation must be a whole word and must PRECEDE the token in the same sentence.
PM_NEGW='(never|must not|do not|don.t|forbid|forbidden|not use|not arm|not rely|no)'
# pm_forbidden_headless <token> — sentences that mention <token>, are headless-scoped and negate it before it.
pm_forbidden_headless() {
  grep -iF -- "$1" | grep -iw 'headless' | grep -iE "\\b${PM_NEGW}\\b[^.;]*$1"
}

pm_check_one_cycle() {  # AC1
  pm_sections "$1" | grep -iw 'headless' | grep -iE 'one (loop )?cycle per launch' | grep -q . \
    || { fail "§3/§4 must say a headless run does one cycle per launch"; return 1; }
  pm_sections "$1" | grep -iE 'launcher|relaunch|cron' | grep -iE 'pac(e|ing)|interval|cadence' | grep -q . \
    || { fail "§3/§4 must say pacing belongs to the launcher"; return 1; }
}
pm_check_forbids() {  # AC2
  local tok
  for tok in 'ScheduleWakeup' 'sleep' 'keep-alive'; do
    pm_sections "$1" | pm_forbidden_headless "$tok" | grep -q . \
      || { fail "§3/§4 must forbid $tok as headless pacing (headless sentence, negation before the token)"; return 1; }
  done
  # no sentence may mention these WITHOUT a negation before the token (i.e. recommend them)
  for tok in 'ScheduleWakeup' 'sleep' 'wakeup' 'keep-alive' 'watcher'; do
    if pm_sections "$1" | grep -iF -- "$tok" | grep -ivE "\\b${PM_NEGW}\\b[^.;]*$tok" | grep -q .; then
      fail "a §3/§4 sentence mentions $tok without a preceding never/forbid clause"; return 1
    fi
  done
}
pm_check_loop_interactive() {  # AC2 (/loop stays interactive-only)
  pm_sections "$1" | grep -F '/loop' | grep -qi 'interactive' \
    || { fail "/loop self-pacing must be stated as interactive-only"; return 1; }
}
pm_check_cadence() {  # AC3
  pm_sections "$1" | grep -E '20.{1,3}30' | grep -iE 'launcher|relaunch|cron' | grep -q . \
    || { fail "20–30 minute cadence must be described as the launcher's interval"; return 1; }
}
pm_check_all() {
  pm_check_one_cycle "$1" && pm_check_forbids "$1" && pm_check_loop_interactive "$1" && pm_check_cadence "$1"
}

pm_write_prefix_fixture() {  # the text as of 2026-09-30, lines 60 and 64 (hand-copied)
  cat > "$1" <<'FX'
## 3. Start-up

You must run as the **main agent of your own session** (interactive with `/loop` self-pacing, or headless), never via the Agent tool — a subagent dies when its parent compacts or exits. Relaunch = resume from the log.

## 4. The loop

Every 20–30 minutes (sooner only when something you just launched should report quickly; never poll tightly, never `sleep` in the foreground):

1. Re-read the plan source.

## 5. Unblocking playbook
FX
}
pm_write_fixed_fixture() {  # hand-written compliant text
  cat > "$1" <<'FX'
## 3. Start-up

Interactive sessions self-pace with `/loop`. A headless (`-p`) run does one cycle per launch: act, append to the log, end the turn. Relaunch = resume from the log.

## 4. The loop

In headless mode the launcher (a cron entry or relaunch loop, like the VM's pm-cycle.sh) sets the pace: it relaunches you every 20–30 minutes. Never use ScheduleWakeup, a background sleep or a keep-alive watcher or Agent for pacing in headless mode; they die when the turn ends.

1. Re-read the plan source.

## 5. Unblocking playbook
FX
}

test_pm109_real_file_one_cycle_per_launch() { pm_check_one_cycle "$PM_MD" && assert_eq 0 0 ok; }
test_pm109_real_file_forbids_wakeup_sleep_keepalive() { pm_check_forbids "$PM_MD" && assert_eq 0 0 ok; }
test_pm109_real_file_loop_interactive_only() { pm_check_loop_interactive "$PM_MD" && assert_eq 0 0 ok; }
test_pm109_real_file_cadence_is_launcher_interval() { pm_check_cadence "$PM_MD" && assert_eq 0 0 ok; }
test_pm109_checker_rejects_prefix_text() {
  local d; d=$(mktemp -d); pm_write_prefix_fixture "$d/pre.md"
  if pm_check_all "$d/pre.md" 2>/dev/null; then rm -rf "$d"; fail "checker accepted the pre-fix text"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "pre-fix rejected"
}
test_pm109_checker_accepts_fixed_text() {
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/fix.md"
  pm_check_all "$d/fix.md" || { rm -rf "$d"; return 1; }
  rm -rf "$d"; assert_eq 0 0 "fixed accepted"
}
test_pm109_checker_rejects_recommended_wakeup() {
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/bad.md"
  sed -i.bak 's/^1\. Re-read the plan source\./Headless runs should arm a ScheduleWakeup for the next check./' "$d/bad.md"
  if pm_check_forbids "$d/bad.md" 2>/dev/null; then rm -rf "$d"; fail "checker accepted a sentence recommending ScheduleWakeup"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "recommendation rejected"
}
test_pm109_checker_rejects_wakeup_with_later_negation() {
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/bad.md"
  sed -i.bak 's/^1\. Re-read the plan source\./Headless runs may use ScheduleWakeup; never sleep in the foreground./' "$d/bad.md"
  if pm_check_forbids "$d/bad.md" 2>/dev/null; then rm -rf "$d"; fail "checker accepted 'may use ScheduleWakeup; never sleep'"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "later negation rejected"
}
test_pm109_checker_rejects_keepalive_allowed() {
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/bad.md"
  sed -i.bak 's/^1\. Re-read the plan source\./Headless runs may use a keep-alive Agent, but never use ScheduleWakeup or sleep in headless mode./' "$d/bad.md"
  sed -i.bak 's/Never use ScheduleWakeup, a background sleep or a keep-alive watcher or Agent for pacing in headless mode; they die when the turn ends\./They die when the turn ends./' "$d/bad.md"
  if pm_check_forbids "$d/bad.md" 2>/dev/null; then rm -rf "$d"; fail "checker accepted keep-alive without a preceding negation"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "keep-alive allowance rejected"
}
test_pm109_checker_rejects_sleep_ban_not_headless_scoped() {
  # only the non-headless "never sleep in the foreground" ban exists -> headless sleep ban missing
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/bad.md"
  sed -i.bak 's/^In headless mode the launcher.*$/The launcher sets the pace every 20–30 minutes. Never use ScheduleWakeup or a keep-alive watcher for pacing in headless mode. Never sleep in the foreground./' "$d/bad.md"
  if pm_check_forbids "$d/bad.md" 2>/dev/null; then rm -rf "$d"; fail "checker accepted a sleep ban that is not headless-scoped"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "unscoped sleep ban rejected"
}
test_pm109_checker_bare_no_is_not_negation() {
  local d; d=$(mktemp -d); pm_write_fixed_fixture "$d/bad.md"
  sed -i.bak 's/^1\. Re-read the plan source\./You know headless runs can use ScheduleWakeup./' "$d/bad.md"
  if pm_check_forbids "$d/bad.md" 2>/dev/null; then rm -rf "$d"; fail "checker treated 'know ' as a negation"; return 1; fi
  rm -rf "$d"; assert_eq 0 0 "know is not a negation"
}
run_test test_pm109_real_file_one_cycle_per_launch
run_test test_pm109_real_file_forbids_wakeup_sleep_keepalive
run_test test_pm109_real_file_loop_interactive_only
run_test test_pm109_real_file_cadence_is_launcher_interval
run_test test_pm109_checker_rejects_prefix_text
run_test test_pm109_checker_accepts_fixed_text
run_test test_pm109_checker_rejects_recommended_wakeup
run_test test_pm109_checker_rejects_wakeup_with_later_negation
run_test test_pm109_checker_rejects_keepalive_allowed
run_test test_pm109_checker_rejects_sleep_ban_not_headless_scoped
run_test test_pm109_checker_bare_no_is_not_negation
