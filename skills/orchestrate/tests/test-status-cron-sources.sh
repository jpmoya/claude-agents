# Follow-up to #756 (status page Jobs tab) — the optional cron[] items' `description` and `source`, the
# argument-qualified job names, and the Mac-only collectors for launchd jobs and Claude desktop scheduled tasks.
#
# Exercised through `report-status.sh --print` (no network). HOME is a fixture directory, so the launchd
# directory, the desktop-task directory and ~/logs are all fixtures; STATUS_CRON_PLATFORM pins the platform
# and TZ=UTC / STATUS_CRON_NOW pin "now" (2026-11-19T10:00:00Z, a Thursday): every expected value below is
# hand-computed from the calendar, never from the code under test. Fixture names are placeholders.

HERE_CSJ=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_CSJ="$HERE_CSJ/.."
CSJ_NOW=1795082400   # 2026-11-19T10:00:00Z (Thursday)

# csj_print <pipe> <home> [platform] [crontab-cmd...] -> the printed payload
csj_print() {
  local pipe=$1 home=$2 platform=${3:-darwin}
  if [ $# -ge 3 ]; then shift 3; else shift $#; fi
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=UTC STATUS_CRON_NOW=$CSJ_NOW STATUS_CRON_CMD="${*:-true}" \
      STATUS_CRON_PLATFORM="$platform" STATUS_LAUNCHD_DIR="$home/Library/LaunchAgents" \
      STATUS_DESKTOP_TASKS_DIR="$home/.claude/scheduled-tasks" "$RS_CSJ/report-status.sh" --print )
}

csj_crontab() {  # csj_crontab <dir> <text> -> path of a crontab fixture file
  printf '%s\n' "$2" > "$1/crontab.txt"
  printf '%s' "$1/crontab.txt"
}

csj_script() {  # csj_script <home> <name> <content> -> a script fixture under <home>/bin
  mkdir -p "$1/bin"
  printf '%s\n' "$3" > "$1/bin/$2"
}

csj_plist() {  # csj_plist <home> <file> <python-dict-literal>
  mkdir -p "$1/Library/LaunchAgents"
  python3 -I -c 'import plistlib, sys, ast
with open(sys.argv[1], "wb") as f:
    plistlib.dump(ast.literal_eval(sys.argv[2]), f)' "$1/Library/LaunchAgents/$2" "$3"
}

csj_touch() {  # csj_touch <file> <epoch>
  python3 -I -c 'import os, sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$1" "$2"
}

csj_job() {  # csj_job <json> <name> <field> [source]
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" --arg s "${4:-}" \
    '.cron[]? | select(.name==$n and ($s == "" or .source == $s)) | .[$f] | if . == null then "null" else tostring end'
}

# ---- description ("What it does") ---------------------------------------------------------------------------

test_csj_description_from_script_header_comment() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  csj_script "$home" layoff-scan-cron.sh '#!/bin/bash
# shellcheck disable=SC2034

# Daily layoff/closure recruiting scan — posts new finds to Slack
# a second comment line is not part of the description
echo hi'
  csj_script "$home" desc-wins.sh '#!/bin/bash
# Some header comment
echo hi
# desc: Weekly pricing check for one supplier'
  csj_script "$home" tilde.sh '# Tilde job runs nightly
echo hi'
  csj_script "$home" homevar.sh '# Home variable job
echo hi'
  ct=$(csj_crontab "$pipe" "0 13 * * * $home/bin/layoff-scan-cron.sh >> ~/logs/x.log 2>&1
0 1 * * * $home/bin/desc-wins.sh
0 2 * * * ~/bin/tilde.sh
0 3 * * * \$HOME/bin/homevar.sh")
  out=$(csj_print "$pipe" "$home" linux cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(csj_job "$out" layoff-scan-cron description)" "Daily layoff/closure recruiting scan — posts new finds to Slack" "first comment line after the shebang (lint pragma skipped); the em dash and the slash survive" || return 1
  assert_eq "$(csj_job "$out" desc-wins description)" "Weekly pricing check for one supplier" "an explicit '# desc:' line wins over the header comment" || return 1
  assert_eq "$(csj_job "$out" tilde description)" "Tilde job runs nightly" "~/ script path resolved" || return 1
  assert_eq "$(csj_job "$out" homevar description)" "Home variable job" "\$HOME/ script path resolved" || return 1
  assert_eq "$(csj_job "$out" layoff-scan-cron source)" "cron" "crontab items carry source cron" || return 1
}

test_csj_description_omitted_when_unresolvable_or_unsafe() {
  local pipe home out ct long
  pipe=$(new_pipe); home=$(new_home)
  printf '%s\n' '# Outside of home so never read' > "$pipe/outside.sh"
  csj_script "$home" url.sh '# Posts to https://hooks.example.test/T/B/X daily'
  csj_script "$home" mail.sh '# Mails someone@example.test every morning'
  csj_script "$home" path.sh '# Reads /etc/secret.conf nightly'
  csj_script "$home" assign.sh '# Needs TOKEN=abc123 set first'
  csj_script "$home" noheader.sh 'echo hi
# a comment after code is not a header'
  long=$(printf 'word %.0s' $(seq 1 60))
  csj_script "$home" long.sh "# $long"
  ct=$(csj_crontab "$pipe" "0 1 * * * $pipe/outside.sh
0 1 * * * ./relative.sh
0 1 * * * $home/bin/url.sh
0 1 * * * $home/bin/mail.sh
0 1 * * * $home/bin/path.sh
0 1 * * * $home/bin/assign.sh
0 1 * * * $home/bin/noheader.sh
0 1 * * * $home/bin/missing.sh
0 1 * * * $home/bin/long.sh")
  out=$(csj_print "$pipe" "$home" linux cat "$ct")
  rm -rf "$pipe" "$home"
  for n in outside relative url mail path assign noheader missing; do
    assert_eq "$(printf '%s' "$out" | jq --arg n "$n" '[.cron[] | select(.name==$n) | has("description")] | .[0]')" "false" "$n: no description key" || return 1
  done
  assert_not_contains "$out" "hooks.example" "a URL in a header comment is never published" || return 1
  assert_not_contains "$out" "someone@" "an email in a header comment is never published" || return 1
  assert_not_contains "$out" "/etc/secret" "a path in a header comment is never published" || return 1
  assert_not_contains "$out" "abc123" "an assignment in a header comment is never published" || return 1
  assert_eq "$(printf '%s' "$out" | jq '[.cron[] | select(.name=="long") | .description | length] | .[0] | . <= 140 and . >= 130')" "true" "capped at 140 characters" || return 1
}

# ---- argument-qualified names ----------------------------------------------------------------------------

test_csj_one_slug_argument_is_appended_to_the_name() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  csj_script "$home" run-pricing-agent.sh '#!/bin/bash
# Pricing agent for one supplier
echo hi'
  ct=$(csj_crontab "$pipe" "0 6 * * 1 $home/bin/run-pricing-agent.sh supplier-a
0 6 1 */3 * $home/bin/run-pricing-agent.sh supplier-b
0 7 1 */3 * $home/bin/run-pricing-agent.sh supplier-c >> ~/logs/x.log 2>&1
0 1 * * * $home/bin/plain.sh --key sk-xyz
0 1 * * * $home/bin/numarg.sh 123
0 1 * * * $home/bin/dotarg.sh a.b
0 1 * * * $home/bin/eqarg.sh mode=fast
0 1 * * * $home/bin/patharg.sh /etc/passwd")
  mkdir -p "$home/logs/run-pricing-agent-supplier-a" "$home/logs/run-pricing-agent"
  printf 'all good\n' > "$home/logs/run-pricing-agent-supplier-a/run.log"
  csj_touch "$home/logs/run-pricing-agent-supplier-a/run.log" 1795000000
  printf 'ERROR boom\n' > "$home/logs/run-pricing-agent/2026-11-supplier-b.log"
  csj_touch "$home/logs/run-pricing-agent/2026-11-supplier-b.log" 1795050000
  out=$(csj_print "$pipe" "$home" linux cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[].name]')" '["run-pricing-agent-supplier-a","run-pricing-agent-supplier-b","run-pricing-agent-supplier-c","plain","numarg","dotarg","eqarg","patharg"]' "slug arguments appended, flags / numbers / dots / assignments / paths never" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-a description)" "Pricing agent for one supplier" "the three jobs share the script's description" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-a last_result)" "ok" "own ~/logs/<name>-<arg>/ dir used first" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-a last_run)" "2026-11-18T11:06:40Z" "own log dir mtime" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-b last_result)" "failed" "shared ~/logs/<script>/: only files named after the argument count" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-c last_result)" "unknown" "another argument's log is never borrowed" || return 1
  assert_eq "$(csj_job "$out" run-pricing-agent-supplier-c last_run)" "null" "no log of its own -> no last_run" || return 1
  assert_not_contains "$out" "sk-xyz" "a flag's value is never published" || return 1
  assert_not_contains "$out" "passwd" "a path argument is never published" || return 1
  assert_not_contains "$out" "mode=fast" "an assignment argument is never published" || return 1
}

# ---- launchd (macOS only) ---------------------------------------------------------------------------------

test_csj_launchd_jobs_listed_with_schedules_and_privacy() {
  local pipe home out mins qbo
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/Library/Logs" "$home/langfuse" "$home/logs/qbo-scraper"
  csj_script "$home" clear-space.sh '#!/bin/bash
# Clear disk space nightly'
  printf 'x\n' > "$home/Library/Logs/clear-space.out.log"; csj_touch "$home/Library/Logs/clear-space.out.log" 1795082300
  printf 'x\n' > "$home/langfuse/cron.log"; csj_touch "$home/langfuse/cron.log" 1795082300
  printf 'ERROR scrape failed\n' > "$home/logs/qbo-scraper/launchd-error.log"; csj_touch "$home/logs/qbo-scraper/launchd-error.log" 1795050000
  csj_plist "$home" com.jp.clear-space.plist "{'Label':'com.jp.clear-space','ProgramArguments':['/bin/bash','$home/bin/clear-space.sh'],'StartCalendarInterval':{'Hour':4,'Minute':0},'StandardOutPath':'$home/Library/Logs/clear-space.out.log','EnvironmentVariables':{'API_KEY':'SECRETENVVALUE'}}"
  qbo=$(python3 -I -c 'print([{"Weekday": w, "Hour": h, "Minute": 0} for w in (4, 5) for h in (10, 12, 14, 16)])')
  csj_plist "$home" com.benjis.qbo-scraper.plist "{'Label':'com.benjis.qbo-scraper','ProgramArguments':['$home/bin/qbo.sh'],'StartCalendarInterval':$qbo}"
  mins=$(python3 -I -c 'print([{"Minute": m} for m in range(1, 60, 2)])')
  csj_plist "$home" com.jp.pipeline-supervisor.plist "{'Label':'com.jp.pipeline-supervisor','ProgramArguments':['$home/bin/sup.sh'],'StartCalendarInterval':$mins}"
  csj_plist "$home" com.jp.langfuse-import.plist "{'Label':'com.jp.langfuse-import','ProgramArguments':['$home/langfuse/sync.sh'],'StartInterval':900,'StandardOutPath':'$home/langfuse/cron.log'}"
  csj_plist "$home" com.xaki.boot-thing.plist "{'Label':'com.xaki.boot-thing','ProgramArguments':['$home/bin/b.sh'],'RunAtLoad':True}"
  csj_plist "$home" com.jpmoya.keeper.plist "{'Label':'com.jpmoya.keeper','ProgramArguments':['$home/bin/k.sh'],'KeepAlive':True}"
  csj_plist "$home" com.jp.manual.plist "{'Label':'com.jp.manual','ProgramArguments':['$home/bin/m.sh']}"
  csj_plist "$home" com.jp.off.plist "{'Label':'com.jp.off','ProgramArguments':['$home/bin/o.sh'],'StartInterval':60,'Disabled':True}"
  csj_plist "$home" com.google.keystone.agent.plist "{'Label':'com.google.keystone.agent','ProgramArguments':['/x/g'],'StartInterval':3600}"
  csj_plist "$home" homebrew.mxcl.redis.plist "{'Label':'homebrew.mxcl.redis','ProgramArguments':['/x/r'],'KeepAlive':True}"
  csj_plist "$home" com.jp.pm-cd.plist.retired "{'Label':'com.jp.pm-cd','ProgramArguments':['/x/p'],'StartInterval':60}"
  printf 'this is not a plist' > "$home/Library/LaunchAgents/com.jp.broken.plist"
  out=$(csj_print "$pipe" "$home" darwin); local rc=$?
  rm -rf "$pipe" "$home"
  assert_exit0 "$rc" "an unreadable plist does not fail the reporter" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[].name] | sort')" '["boot-thing","clear-space","keeper","langfuse-import","pipeline-supervisor","qbo-scraper"]' "our prefixes only; manual, disabled, Google, homebrew, .retired and broken plists skipped; names drop the vendor prefix" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[].source] | unique')" '["launchd"]' "source launchd" || return 1
  # a single calendar entry
  assert_eq "$(csj_job "$out" clear-space schedule)" "0 4 * * *" "calendar dict -> cron expression" || return 1
  assert_eq "$(csj_job "$out" clear-space schedule_human)" "Daily at 04:00" "human" || return 1
  assert_eq "$(csj_job "$out" clear-space next_run)" "2026-11-20T04:00:00Z" "next 04:00 after Thu 10:00" || return 1
  assert_eq "$(csj_job "$out" clear-space description)" "Clear disk space nightly" "description from the ProgramArguments script under home (the interpreter is skipped)" || return 1
  assert_eq "$(csj_job "$out" clear-space last_run)" "2026-11-19T09:58:20Z" "last_run from the plist's StandardOutPath mtime" || return 1
  assert_eq "$(csj_job "$out" clear-space last_result)" "unknown" "result is never taken from a plist log path" || return 1
  # a cross product of weekdays and hours
  assert_eq "$(csj_job "$out" qbo-scraper schedule)" "0 10-16/2 * * 4,5" "list of dicts that is a cross product -> one expression" || return 1
  assert_eq "$(csj_job "$out" qbo-scraper schedule_human)" "Thursdays and Fridays at 10:00, 12:00, 14:00 and 16:00" "human" || return 1
  assert_eq "$(csj_job "$out" qbo-scraper next_run)" "2026-11-19T12:00:00Z" "Thursday 12:00 is the next slot after 10:00" || return 1
  assert_eq "$(csj_job "$out" qbo-scraper last_result)" "failed" "result from ~/logs/<name>/" || return 1
  assert_eq "$(csj_job "$out" qbo-scraper last_run)" "2026-11-19T01:00:00Z" "last_run from ~/logs/<name>/" || return 1
  # thirty odd minutes fit the 60-character schedule cap as a step range
  assert_eq "$(csj_job "$out" pipeline-supervisor schedule)" "1-59/2 * * * *" "arithmetic progression compressed" || return 1
  assert_eq "$(csj_job "$out" pipeline-supervisor schedule_human)" "Every 2 minutes" "human" || return 1
  assert_eq "$(csj_job "$out" pipeline-supervisor next_run)" "2026-11-19T10:01:00Z" "next odd minute" || return 1
  # interval, run-at-load, keep-alive
  assert_eq "$(csj_job "$out" langfuse-import schedule)" "@every 900s" "StartInterval" || return 1
  assert_eq "$(csj_job "$out" langfuse-import schedule_human)" "Every 15 minutes" "human" || return 1
  assert_eq "$(csj_job "$out" langfuse-import next_run)" "2026-11-19T10:13:20Z" "last_run (09:58:20) + 900 s" || return 1
  assert_eq "$(csj_job "$out" boot-thing schedule)" "@reboot" "RunAtLoad only" || return 1
  assert_eq "$(csj_job "$out" boot-thing schedule_human)" "At login" "human" || return 1
  assert_eq "$(csj_job "$out" boot-thing next_run)" "null" "no next run" || return 1
  assert_eq "$(csj_job "$out" keeper schedule)" "@keepalive" "KeepAlive" || return 1
  assert_eq "$(csj_job "$out" keeper schedule_human)" "Kept running" "human" || return 1
  assert_not_contains "$out" "SECRETENVVALUE" "plist environment values are never published" || return 1
  assert_not_contains "$out" "$home" "no path is published" || return 1
  assert_not_contains "$out" "ProgramArguments" "no plist key is published" || return 1
}

test_csj_launchd_not_collected_off_macos_or_when_switched_off() {
  local pipe home out out2
  pipe=$(new_pipe); home=$(new_home)
  csj_plist "$home" com.jp.clear-space.plist "{'Label':'com.jp.clear-space','ProgramArguments':['/bin/true'],'StartInterval':60}"
  mkdir -p "$home/.claude/scheduled-tasks/some-task"
  printf -- '---\nname: some-task\ndescription: A task\n---\nbody\n' > "$home/.claude/scheduled-tasks/some-task/SKILL.md"
  out=$(csj_print "$pipe" "$home" linux)
  out2=$( ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=UTC STATUS_CRON_NOW=$CSJ_NOW STATUS_CRON_CMD=true \
      STATUS_CRON_PLATFORM=darwin STATUS_LAUNCHD_DIR="" STATUS_DESKTOP_TASKS_DIR="" "$RS_CSJ/report-status.sh" --print ) )
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq 'has("cron")')" "false" "on Linux neither the launchd nor the desktop collector runs" || return 1
  assert_eq "$(printf '%s' "$out2" | jq 'has("cron")')" "false" "an empty STATUS_LAUNCHD_DIR / STATUS_DESKTOP_TASKS_DIR switches both off" || return 1
}

# ---- Claude desktop scheduled tasks (macOS only) ---------------------------------------------------------

test_csj_desktop_tasks_listed_by_name_and_description() {
  local pipe home out t
  pipe=$(new_pipe); home=$(new_home)
  t="$home/.claude/scheduled-tasks"
  mkdir -p "$t/daily-scan" "$t/quoted-one" "$t/with-email" "$t/block-desc" "$t/no-skill" "$t/with-log"
  printf -- '---\nname: daily-scan\ndescription: Daily search for layoffs/closures at related firms, posted to #sourcing\n---\n\nBODYSECRETTEXT never published\n' > "$t/daily-scan/SKILL.md"
  printf -- '---\nname: quoted-one\ndescription: "Quoted one: still fine"\n---\nbody\n' > "$t/quoted-one/SKILL.md"
  printf -- '---\nname: with-email\ndescription: Draft follow-ups for someone@example.test\n---\nbody\n' > "$t/with-email/SKILL.md"
  printf -- '---\nname: block-desc\ndescription: >\n  Folded description line\n---\nbody\n' > "$t/block-desc/SKILL.md"
  printf -- '---\nname: with-log\ndescription: Has a log dir\n---\nbody\n' > "$t/with-log/SKILL.md"
  mkdir -p "$home/logs/with-log"; printf 'fatal: nope\n' > "$home/logs/with-log/run.log"; csj_touch "$home/logs/with-log/run.log" 1795050000
  printf 'x\n' > "$t/stray-file.md"
  out=$(csj_print "$pipe" "$home" darwin)
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[].name] | sort')" '["block-desc","daily-scan","quoted-one","with-email","with-log"]' "one entry per task directory that has a SKILL.md" || return 1
  assert_eq "$(csj_job "$out" daily-scan source)" "desktop" "source desktop" || return 1
  assert_eq "$(csj_job "$out" daily-scan schedule)" "@app" "the schedule lives in the app: sentinel" || return 1
  assert_eq "$(csj_job "$out" daily-scan schedule_human)" "Set in the Claude app" "human" || return 1
  assert_eq "$(csj_job "$out" daily-scan next_run)" "null" "no next run" || return 1
  assert_eq "$(csj_job "$out" daily-scan last_run)" "null" "no log dir -> never" || return 1
  assert_eq "$(csj_job "$out" daily-scan description)" "Daily search for layoffs/closures at related firms, posted to #sourcing" "frontmatter description" || return 1
  assert_eq "$(csj_job "$out" quoted-one description)" "Quoted one: still fine" "surrounding quotes removed" || return 1
  assert_eq "$(csj_job "$out" block-desc description)" "Folded description line" "a block scalar's first line" || return 1
  assert_eq "$(printf '%s' "$out" | jq '[.cron[] | select(.name=="with-email") | has("description")] | .[0]')" "false" "a description with an email is dropped" || return 1
  assert_eq "$(csj_job "$out" with-log last_result)" "failed" "result from ~/logs/<name>/ when it exists" || return 1
  assert_not_contains "$out" "BODYSECRETTEXT" "the task body is never published" || return 1
  assert_not_contains "$out" "someone@" "an email is never published" || return 1
}

test_csj_mac_jobs_still_listed_when_the_crontab_is_missing_or_unreadable() {
  local pipe home out out2
  pipe=$(new_pipe); home=$(new_home)
  csj_plist "$home" com.jp.clear-space.plist "{'Label':'com.jp.clear-space','ProgramArguments':['/bin/true'],'StartInterval':600}"
  printf '#!/bin/bash\necho "no crontab for someone" >&2\nexit 1\n' > "$pipe/nocrontab"; chmod +x "$pipe/nocrontab"
  out=$(csj_print "$pipe" "$home" darwin "$pipe/nocrontab")
  out2=$(csj_print "$pipe" "$home" darwin /bin/false); local rc=$?
  rm -rf "$pipe" "$home"
  assert_eq "$(csj_job "$out" clear-space source)" "launchd" "no crontab: the launchd jobs are still collected" || return 1
  assert_exit0 "$rc" "an unreadable crontab does not fail the reporter" || return 1
  assert_eq "$(csj_job "$out2" clear-space source)" "launchd" "unreadable crontab: the launchd jobs are still collected" || return 1
}

test_csj_crontab_and_mac_sources_are_combined_in_one_list() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/.claude/scheduled-tasks/a-task"
  printf -- '---\nname: a-task\ndescription: A desktop task\n---\n' > "$home/.claude/scheduled-tasks/a-task/SKILL.md"
  csj_plist "$home" com.jp.clear-space.plist "{'Label':'com.jp.clear-space','ProgramArguments':['/bin/true'],'StartInterval':600}"
  ct=$(csj_crontab "$pipe" '0 1 * * * a-cron-job.sh')
  out=$(csj_print "$pipe" "$home" darwin cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[] | [.source, .name]]')" '[["cron","a-cron-job"],["launchd","clear-space"],["desktop","a-task"]]' "crontab first, then launchd, then desktop tasks" || return 1
}

run_test test_csj_description_from_script_header_comment
run_test test_csj_description_omitted_when_unresolvable_or_unsafe
run_test test_csj_one_slug_argument_is_appended_to_the_name
run_test test_csj_launchd_jobs_listed_with_schedules_and_privacy
run_test test_csj_launchd_not_collected_off_macos_or_when_switched_off
run_test test_csj_desktop_tasks_listed_by_name_and_description
run_test test_csj_mac_jobs_still_listed_when_the_crontab_is_missing_or_unreadable
run_test test_csj_crontab_and_mac_sources_are_combined_in_one_list
