# Issue #182 — daily cap on automatic Sentry-ticket launches per repo: config, label helper, the launch log and the
# orchestrate.sh refusal (the place every launch passes, PM readiness note on the ticket). The supervisor's step-5
# pre-check is in test-issue182-sentry-cap-supervisor.sh.
#
#   AC1  fixture 5: `intake-labels.sh bug sentry` with SENTRY_AUTO_GO=1 -> agent-go + sentry-auto-go; unset -> agent-proposed,
#        no sentry-auto-go; every other #176 output unchanged
#   AC2  config.sh defines SENTRY_AUTO_GO_DAILY_CAP=3 with a comment stating the worst-case spend (cap x COST_CEILING_USD)
#   AC4  the launch log is append-only; a missing file counts as zero launches
#   PM   orchestrate.sh on a sentry-auto-go issue with a full log -> exit 3 with the exact message, no claim comment, no
#        process; --force does not bypass; SENTRY_CAP_BYPASS=1 does; a source:sentry issue without the label launches;
#        the launch line is appended after a successful launch; agents/intake.md leaves the label to the supervisor
#   Rev  (code review of PR #683) gate and append are serialised per repo by a mkdir lock with a stale takeover; a launch
#        counted at queue time gives its place back when the entry is dropped before it started (`released` line)
#   Obs  a failed read of the launch log or of the issue labels fails closed, is logged with release / environment /
#        route=sentry-launch-cap and alerts once on the existing Slack webhook, with no secret or issue text
#
# Expected values are hand-written from the ticket (cap 3, window 86400 s, line = "<epoch> <owner/repo> <issue>").

HERE_SCT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_SCT/lib/sentry-cap.sh"
IL_SC="$RS_SC/intake-labels.sh"

# sc_ops <config.local.sh lines or ""> <args...> -> SC_RC, SC_OUT (sorted, comma-joined; the test-intake-labels.sh convention)
sc_ops() {
  local env_lines=$1 home out; shift
  home=$(new_home)
  [ -z "$env_lines" ] || printf '%s\n' "$env_lines" > "$home/.claude/pipeline/config.local.sh"
  out=$(HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$IL_SC" "$@" 2>/dev/null); SC_RC=$?
  rm -rf "$home"
  SC_OUT=$(printf '%s\n' "$out" | sort | tr '\n' ',')
}

# ------------------------------------------------------------------------------------------ AC1 fixture 5: label helper

test_sc_labels_sentry_auto_go_on_adds_go_and_sentry_auto_go() {
  local v
  for v in 0 1; do
    sc_ops "$(printf 'INTAKE_AUTO_GO=%s\nSENTRY_AUTO_GO=1' "$v")" bug sentry
    assert_exit0 "$SC_RC" "bug sentry exits 0" || return 1
    assert_eq "$SC_OUT" "add agent-go,add bug,add sentry-auto-go,add user-feedback,remove user-feedback-intake," \
      "fixture 5: SENTRY_AUTO_GO=1 (INTAKE_AUTO_GO=$v) adds agent-go and sentry-auto-go" || return 1
  done
}

test_sc_labels_sentry_auto_go_off_is_proposed_without_the_label() {
  local e
  for e in "" "SENTRY_AUTO_GO=0" "INTAKE_AUTO_GO=1"; do
    sc_ops "$e" bug sentry
    assert_eq "$SC_OUT" "add agent-proposed,add bug,add user-feedback,remove user-feedback-intake," \
      "fixture 5: SENTRY_AUTO_GO off ($e) -> agent-proposed, no sentry-auto-go" || return 1
  done
}

test_sc_labels_other_outputs_never_carry_sentry_auto_go() {
  # noise, and every non-Sentry type (a ticket JP or staff reported), stay exactly as #114/#176 defined them
  sc_ops "SENTRY_AUTO_GO=1" noise sentry
  assert_eq "$SC_OUT" "add sentry-noise,remove user-feedback-intake," "noise sentry unchanged" || return 1
  sc_ops "$(printf 'INTAKE_AUTO_GO=1\nSENTRY_AUTO_GO=1')" bug
  assert_eq "$SC_OUT" "add agent-go,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "staff bug unchanged" || return 1
  sc_ops "$(printf 'INTAKE_AUTO_GO=1\nSENTRY_AUTO_GO=1')" idea
  assert_eq "$SC_OUT" "add user-feedback,add user-feedback-needs-spec,remove user-feedback-intake," "staff idea unchanged" || return 1
}

test_sc_intake_md_leaves_the_label_to_the_supervisor() {
  # since #186 a source:sentry run cannot write labels: sentry-auto-go is the supervisor's, when the helper prints it
  local md="$ROOT_SC/agents/intake.md" forb line own
  forb=$(awk '/^## Forbidden/{on=1;next} on{print}' "$md")
  line=$(printf '%s\n' "$forb" | grep 'sentry-auto-go')
  own=$(printf '%s\n' "$forb" | grep 'adding any label outside')
  assert_contains "$forb" '`sentry-auto-go`' "intake.md Forbidden names sentry-auto-go" || return 1
  assert_contains "$line" "only the supervisor applies" "the label is the supervisor's to apply" || return 1
  assert_contains "$line" "helper prints it" "and only when the helper prints it" || return 1
  assert_contains "$own" "sentry-noise" "control: the agent's own label list is still there" || return 1
  assert_not_contains "$own" "sentry-auto-go" "the agent's own label list does not carry sentry-auto-go" || return 1
  grep -qF 'Nothing in the decision file can add `agent-go` or `sentry-auto-go`' "$md" \
    || { fail "intake.md: the decision file can add neither agent-go nor sentry-auto-go"; return 1; }
}

# ------------------------------------------------------------------------------------------ AC2: config

test_sc_config_defines_the_cap_with_the_worst_case_spend() {
  local cfg="$RS_SC/config.sh" line n block
  line=$(grep -E '^SENTRY_AUTO_GO_DAILY_CAP=' "$cfg")
  assert_eq "${line%%[[:space:]#]*}" "SENTRY_AUTO_GO_DAILY_CAP=3" "AC2: config.sh sets SENTRY_AUTO_GO_DAILY_CAP=3" || return 1
  n=$(grep -nE '^SENTRY_AUTO_GO_DAILY_CAP=' "$cfg" | cut -d: -f1)
  # the comment block directly above the key (consecutive # lines)
  block=$(awk -v n="$n" 'NR < n {if ($0 ~ /^#/) buf = buf $0 "\n"; else buf = ""} NR == n {printf "%s", buf}' "$cfg")
  assert_contains "$block" "COST_CEILING_USD" "AC2: the comment names COST_CEILING_USD" || return 1
  printf '%s' "$block" | grep -qi 'worst' || { fail "AC2: the comment states the worst-case spend"; return 1; }
  # cap 3 x COST_CEILING_USD 40 = 120 (hand arithmetic from the ticket)
  assert_eq "$(grep -E '^COST_CEILING_USD=' "$cfg" | sed -E 's/^COST_CEILING_USD=([0-9]+).*/\1/')" "40" "control: per-ticket ceiling is 40" || return 1
  assert_contains "$block" '$120' "AC2: the comment gives the worst case in dollars (3 x \$40)" || return 1
}

test_sc_config_cap_is_overridable_in_config_local() {
  sc_env; local d o
  d=$(sc_lib 'echo "$SENTRY_AUTO_GO_DAILY_CAP"')
  echo 'SENTRY_AUTO_GO_DAILY_CAP=7' >> "$SC_HOME/.claude/pipeline/config.local.sh"
  o=$(sc_lib 'echo "$SENTRY_AUTO_GO_DAILY_CAP"')
  sc_cleanup
  assert_eq "$d" "3" "default cap is 3" || return 1
  assert_eq "$o" "7" "config.local.sh overrides the cap" || return 1
}

# ------------------------------------------------------------------------------------------ AC4: the launch log

test_sc_count_missing_file_is_zero() {
  sc_env; local n rc
  n=$(sc_lib "sentry_launch_count $SC_A"); rc=$?
  sc_cleanup
  assert_eq "$rc" "0" "AC4: a missing log is not an error" || return 1
  assert_eq "$n" "0" "AC4: a missing log counts as zero launches" || return 1
}

test_sc_count_is_per_repo_and_inside_the_24h_window() {
  sc_env; local a b c
  # repo A: 3 inside the window (10 min, 1 h, 23 h 59 min), 2 outside (24 h + 1 min, 25 h); repo B: 1 inside
  sc_seed "$SC_A" 600 3600 86340 86460 90000
  sc_seed "$SC_B" 60
  a=$(sc_lib "sentry_launch_count $SC_A"); b=$(sc_lib "sentry_launch_count $SC_B"); c=$(sc_lib "sentry_launch_count project-c/repo-c")
  sc_cleanup
  assert_eq "$a" "3" "repo A: only the 3 launches of the last 86400 s count" || return 1
  assert_eq "$b" "1" "repo B: its own launch only (counters are per repo)" || return 1
  assert_eq "$c" "0" "a repo with no line counts zero" || return 1
}

test_sc_count_ignores_malformed_lines_and_repo_case() {
  sc_env; local now a
  now=$(date +%s)
  { printf '%s %s 11\n' "$((now - 5))" "Project-A/Repo-A"   # GitHub names are case-insensitive
    printf 'garbage line\n'; printf '\n'; printf '%s %s\n' "$((now - 5))" "$SC_A"   # no issue field
    printf 'notanumber %s 12\n' "$SC_A"
    printf '%s %s 13\n' "$((now - 5))" "$SC_A"; } > "$SC_LOG"
  a=$(sc_lib "sentry_launch_count $SC_A")
  sc_cleanup
  assert_eq "$a" "2" "only well-formed lines of the repo count (case-insensitive name)" || return 1
}

test_sc_record_appends_one_line_and_keeps_earlier_ones() {
  sc_env; local before after first last now
  printf '1 project-x/old 5\n' > "$SC_LOG"; sc_seed "$SC_A" 50
  before=$(cat "$SC_LOG"); now=$(date +%s)
  sc_lib "sentry_launch_record $SC_A 42; sentry_launch_record $SC_B 43"
  after=$(cat "$SC_LOG"); first=$(printf '%s\n' "$after" | sed -n 1,2p); last=$(printf '%s\n' "$after" | sed -n 3,4p)
  local n; n=$(sc_log_lines)
  sc_cleanup
  assert_eq "$n" "4" "AC4: two launches append two lines" || return 1
  assert_eq "$first" "$before" "AC4: earlier lines are byte-identical (append-only)" || return 1
  printf '%s\n' "$last" | sed -n 1p | grep -qE "^[0-9]+ $SC_A 42\$" || { fail "line shape must be '<epoch> <owner/repo> <issue>', got: $last"; return 1; }
  printf '%s\n' "$last" | sed -n 2p | grep -qE "^[0-9]+ $SC_B 43\$" || { fail "second line shape, got: $last"; return 1; }
  local e; e=$(printf '%s\n' "$last" | sed -n 1p | cut -d' ' -f1)
  [ "$e" -ge "$now" ] && [ "$e" -le "$((now + 60))" ] || { fail "epoch $e is not the launch time (~$now)"; return 1; }
}

test_sc_no_script_truncates_or_removes_the_launch_log() {
  # static half of "append-only": every redirect into the log is >>, nothing deletes, moves or rotates it
  local hits bad
  hits=$(grep -n 'sentry-launches\.log' "$RS_SC"/*.sh)
  assert_contains "$hits" 'sentry-launches.log' "control: the scripts name the log" || return 1
  bad=$(printf '%s\n' "$hits" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | grep -E '(^|[^>])>[[:space:]]*"?\$\{?PIPE\}?/sentry-launches|(^|[^a-z])(rm|mv|cp|truncate) [^#]*sentry-launches' || true)
  assert_eq "$bad" "" "AC4: no truncating write, rm, mv or cp of the launch log" || return 1
  assert_eq "$(grep -c 'sentry-launches' "$RS_SC/rotate-logs.sh")" "0" "AC4: log rotation leaves the launch log alone" || return 1
}

test_sc_gate_under_cap_at_cap_and_unreadable() {
  sc_env; local under at over zero bad
  sc_seed "$SC_A" 60 120
  under=$(sc_lib "sentry_cap_gate $SC_A 7; echo \"rc=\$? n=\$SENTRY_CAP_N max=\$SENTRY_CAP_MAX\"")
  sc_seed "$SC_A" 180
  at=$(sc_lib "sentry_cap_gate $SC_A 7; echo \"rc=\$? n=\$SENTRY_CAP_N max=\$SENTRY_CAP_MAX\"")
  sc_seed "$SC_A" 240
  over=$(sc_lib "sentry_cap_gate $SC_A 7; echo \"rc=\$? n=\$SENTRY_CAP_N max=\$SENTRY_CAP_MAX\"")
  echo 'SENTRY_AUTO_GO_DAILY_CAP=0' >> "$SC_HOME/.claude/pipeline/config.local.sh"
  zero=$(sc_lib "sentry_cap_gate $SC_B 7; echo \"rc=\$? n=\$SENTRY_CAP_N max=\$SENTRY_CAP_MAX\"")
  rm -f "$SC_LOG"; mkdir "$SC_LOG"   # a path that exists but is not a readable file (works for root too)
  bad=$(sc_lib "sentry_cap_gate $SC_A 7 2>/dev/null; echo \"rc=\$?\"")
  sc_cleanup
  assert_eq "$under" "rc=0 n=2 max=3" "2 of 3: may launch" || return 1
  assert_eq "$at" "rc=3 n=3 max=3" "3 of 3: at the cap" || return 1
  assert_eq "$over" "rc=3 n=4 max=3" "4 of 3: above the cap" || return 1
  assert_eq "$zero" "rc=3 n=0 max=0" "cap 0: nothing launches automatically" || return 1
  assert_eq "$bad" "rc=1" "unreadable log: neither 'may launch' nor 'at the cap' (fail closed)" || return 1
}

# ------------------------------------------------------------------------------------------ orchestrate.sh (PM note 2)

test_sc_orch_full_log_refuses_with_exit_3_and_touches_nothing() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go sentry-auto-go source:sentry user-feedback bug
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local calls labels n lines pidf=absent q=absent
  calls=$(cat "$SC_D/gh-calls.log"); labels=$(sc_labels 7); n=$(sc_orch_launches); lines=$(sc_log_lines)
  ls "$SC_PIPE"/orch-*.pid >/dev/null 2>&1 && pidf=present
  ls "$SC_PIPE"/queue/*.json >/dev/null 2>&1 && q=present
  sc_cleanup
  assert_eq "$rc" "3" "full log: exit 3" || return 1
  assert_contains "$out" "sentry launch cap reached for $SC_A (3/3 in 24h)" "exact refusal message" || return 1
  assert_not_contains "$calls" "issue comment" "no claim comment" || return 1
  assert_not_contains "$calls" "issue edit" "no label write" || return 1
  assert_eq "$labels" "agent-go,bug,sentry-auto-go,source:sentry,user-feedback" "labels unchanged (still queued)" || return 1
  assert_eq "$n" "0" "no process" || return 1
  assert_eq "$pidf" "absent" "no pid file" || return 1
  assert_eq "$q" "absent" "not queued either" || return 1
  assert_eq "$lines" "3" "a refused launch appends nothing" || return 1
}

test_sc_orch_force_does_not_bypass_the_cap() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go sentry-auto-go source:sentry
  local out rc; out=$(sc_launch "$SC_RA" 7 --force); rc=$?
  local n; n=$(sc_orch_launches)
  sc_cleanup
  assert_eq "$rc" "3" "--force: still exit 3" || return 1
  assert_contains "$out" "sentry launch cap reached for $SC_A (3/3 in 24h)" "--force: same refusal" || return 1
  assert_eq "$n" "0" "--force: no process" || return 1
}

test_sc_orch_bypass_env_launches_and_records() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go sentry-auto-go source:sentry
  SC_BYPASS=1
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n lines last; n=$(sc_orch_launches); lines=$(sc_log_lines); last=$(tail -1 "$SC_LOG")
  sc_cleanup
  assert_eq "$rc" "0" "SENTRY_CAP_BYPASS=1: exit 0" || return 1
  assert_contains "$out" "launched orchestrator for $SC_A#7" "SENTRY_CAP_BYPASS=1: launched" || return 1
  assert_eq "$n" "1" "SENTRY_CAP_BYPASS=1: one orchestrator process" || return 1
  assert_eq "$lines" "4" "a bypassed launch is still a counted launch" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_A 7\$" || { fail "appended line shape, got: $last"; return 1; }
}

test_sc_orch_bypass_only_on_exactly_one() {
  # control for the bypass: any other value keeps the cap (same fixture, refused)
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go sentry-auto-go
  SC_BYPASS=yes
  local rc; sc_launch "$SC_RA" 7 >/dev/null; rc=$?
  sc_cleanup
  assert_eq "$rc" "3" "SENTRY_CAP_BYPASS=yes does not bypass" || return 1
}

test_sc_orch_hand_released_sentry_ticket_is_never_throttled() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go source:sentry user-feedback bug   # JP released it by hand: no sentry-auto-go
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n lines; n=$(sc_orch_launches); lines=$(sc_log_lines)
  sc_cleanup
  assert_eq "$rc" "0" "source:sentry without sentry-auto-go: exit 0 with a full log" || return 1
  assert_contains "$out" "launched orchestrator for $SC_A#7" "launched" || return 1
  assert_eq "$n" "1" "one orchestrator process" || return 1
  assert_eq "$lines" "3" "a hand-released ticket is not counted either" || return 1
}

test_sc_orch_under_cap_launches_and_appends_after_the_launch() {
  sc_env; sc_seed "$SC_A" 600 1800      # 2 of 3
  sc_seed "$SC_B" 10 20 30              # another repo's full log is irrelevant
  sc_issue 7 "$SC_A" agent-go sentry-auto-go source:sentry
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n lines last labels a; n=$(sc_orch_launches); lines=$(sc_log_lines); last=$(tail -1 "$SC_LOG"); labels=$(sc_labels 7)
  a=$(sc_lib "sentry_launch_count $SC_A")
  # the next sentry-auto-go ticket of the same repo now meets a full window
  sc_issue 8 "$SC_A" agent-go sentry-auto-go
  local out2 rc2; out2=$(sc_launch "$SC_RA" 8); rc2=$?
  sc_cleanup
  assert_eq "$rc" "0" "2 of 3: exit 0" || return 1
  assert_eq "$n" "1" "2 of 3: launched" || return 1
  assert_eq "$lines" "6" "exactly one line appended" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_A 7\$" || { fail "appended line shape, got: $last"; return 1; }
  assert_eq "$a" "3" "the launch counts toward the repo's window" || return 1
  assert_eq "$labels" "agent-in-progress,sentry-auto-go,source:sentry" "agent-go consumed, sentry-auto-go kept" || return 1
  assert_eq "$rc2" "3" "the 4th launch of the window is refused" || return 1
  assert_contains "$out2" "sentry launch cap reached for $SC_A (3/3 in 24h)" "refusal names the count" || return 1
}

test_sc_orch_lost_claim_appends_nothing() {
  # "A launch appends its line only after the claim is won": another host's earlier claim -> refused, nothing counted
  sc_env
  sc_issue 7 "$SC_A" agent-go sentry-auto-go
  local t; t=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  jq -n --arg t "$t" '[{body: ("**[supervisor] NOTE** claim: otherhost " + $t), createdAt: $t}]' > "$SC_D/comments.json"
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n lines; n=$(sc_orch_launches); lines=$(sc_log_lines)
  sc_cleanup
  assert_eq "$rc" "1" "lost claim: exit 1" || return 1
  assert_contains "$out" "lost claim to otherhost" "control: the claim was lost" || return 1
  assert_eq "$n" "0" "lost claim: no process" || return 1
  assert_eq "$lines" "0" "lost claim: no launch line" || return 1
}

test_sc_orch_queued_launch_takes_its_slot_at_queue_time() {
  # no free slot: the launch is accepted into the queue (agent-go consumed, the drain starts it with no second check),
  # so it is counted now; otherwise a full machine would let any number of capped tickets queue up
  sc_env 'MAX_CONCURRENT=0' 'SENTRY_AUTO_GO_DAILY_CAP=1'
  sc_issue 7 "$SC_A" agent-go sentry-auto-go; sc_issue 8 "$SC_A" agent-go sentry-auto-go
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local lines q=absent slot; lines=$(sc_log_lines); ls "$SC_PIPE"/queue/*.json >/dev/null 2>&1 && q=present
  slot=$(jq -r '.sentry_slot // "none"' "$SC_PIPE"/queue/*.json 2>/dev/null)
  local out2 rc2; out2=$(sc_launch "$SC_RA" 8); rc2=$?
  sc_cleanup
  assert_eq "$rc" "0" "queued: exit 0" || return 1
  assert_contains "$out" "queued #7" "control: the launch was queued" || return 1
  assert_eq "$q" "present" "queue entry written" || return 1
  assert_eq "$lines" "1" "the queued launch is counted" || return 1
  assert_eq "$slot" "$SC_A" "the queue entry remembers its counted place" || return 1
  assert_eq "$rc2" "3" "cap 1: the next ticket is refused" || return 1
  assert_contains "$out2" "sentry launch cap reached for $SC_A (1/1 in 24h)" "refusal uses the configured cap" || return 1
}

test_sc_orch_label_flag_from_the_supervisor_skips_the_label_read() {
  # step 5 already knows the label from its listing: SENTRY_CAP_LABELLED=1|0 means no second GitHub read
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go
  SC_LABELLED=1
  local rc; sc_launch "$SC_RA" 7 --force >/dev/null; rc=$?
  local reads; reads=$(sc_label_reads "$SC_A" 7)
  SC_LABELLED=0
  local rc0; sc_launch "$SC_RA" 7 --force >/dev/null; rc0=$?
  local reads0; reads0=$(sc_label_reads "$SC_A" 7)
  SC_LABELLED=""
  sc_issue 9 "$SC_A" agent-go sentry-auto-go
  local rc9; sc_launch "$SC_RA" 9 --force >/dev/null; rc9=$?
  local reads9; reads9=$(sc_label_reads "$SC_A" 9)
  sc_cleanup
  assert_eq "$rc" "3" "SENTRY_CAP_LABELLED=1: gated without reading labels" || return 1
  assert_eq "$reads" "0" "SENTRY_CAP_LABELLED=1: no label read" || return 1
  assert_eq "$rc0" "0" "SENTRY_CAP_LABELLED=0: not gated" || return 1
  assert_eq "$reads0" "0" "SENTRY_CAP_LABELLED=0: no label read" || return 1
  assert_eq "$rc9" "3" "no flag: the label is read here and the cap applies" || return 1
  assert_eq "$reads9" "1" "no flag: exactly one label read" || return 1
}

# ------------------------------------------------------------------------------------------ observability (PM note 5)

test_sc_orch_unreadable_launch_log_fails_closed_tagged_and_alerted() {
  sc_env; mkdir "$SC_LOG"   # exists, cannot be read as a file
  sc_issue 7 "$SC_A" agent-go sentry-auto-go; sc_issue 8 "$SC_A" agent-go
  SC_WEBHOOK=https://hooks.example.test/x
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n calls alert ev labels; n=$(sc_orch_launches); calls=$(cat "$SC_D/gh-calls.log"); alert=$(cat "$SC_D/curl.log")
  ev=$(cat "$SC_HOME/logs/pipeline/events.jsonl" 2>/dev/null); labels=$(sc_labels 7)
  # a second failure inside the hour is logged again but not alerted again
  sc_launch "$SC_RA" 7 >/dev/null
  local alerts; alerts=$(grep -c 'hooks.example.test' "$SC_D/curl.log")
  # control: a ticket without the label is not affected by the broken log
  local rc8; sc_launch "$SC_RA" 8 >/dev/null; rc8=$?
  sc_cleanup
  assert_ne "$rc" "0" "unreadable log: refused" || return 1
  assert_ne "$rc" "3" "unreadable log: not reported as 'cap reached'" || return 1
  assert_eq "$n" "0" "unreadable log: no process (fail closed)" || return 1
  assert_not_contains "$calls" "issue comment" "unreadable log: no claim comment" || return 1
  assert_eq "$labels" "agent-go,sentry-auto-go" "unreadable log: labels untouched" || return 1
  assert_contains "$out" "route=sentry-launch-cap" "tagged line: route" || return 1
  assert_contains "$out" "release=" "tagged line: release" || return 1
  assert_contains "$out" "environment=" "tagged line: environment" || return 1
  assert_contains "$out" "$SC_A#7" "tagged line: repo and issue number" || return 1
  assert_contains "$ev" '"route":"sentry-launch-cap"' "events row: route" || return 1
  assert_contains "$ev" '"release":' "events row: release" || return 1
  assert_contains "$alert" "hooks.example.test" "alert sent on the existing Slack webhook" || return 1
  assert_contains "$alert" "release=" "alert payload: release tag" || return 1
  assert_contains "$alert" "environment=" "alert payload: environment tag" || return 1
  assert_contains "$alert" "route=sentry-launch-cap" "alert payload: route tag" || return 1
  assert_not_contains "$alert" "Jane Doe" "alert payload carries no issue text" || return 1
  assert_eq "$alerts" "1" "one alert, not one per attempt" || return 1
  assert_eq "$rc8" "0" "control: a ticket without sentry-auto-go still launches" || return 1
}

test_sc_orch_failed_label_read_fails_closed_tagged_and_alerted() {
  sc_env; touch "$SC_D/labels-fail"
  sc_issue 7 "$SC_A" agent-go sentry-auto-go
  SC_WEBHOOK=https://hooks.example.test/x
  local out rc; out=$(sc_launch "$SC_RA" 7); rc=$?
  local n calls alert ev; n=$(sc_orch_launches); calls=$(cat "$SC_D/gh-calls.log"); alert=$(cat "$SC_D/curl.log")
  ev=$(cat "$SC_HOME/logs/pipeline/events.jsonl" 2>/dev/null)
  # JP's deliberate hand launch is not blocked by the failed read: it goes through, uncounted
  SC_BYPASS=1
  local out3 rc3; out3=$(sc_launch "$SC_RA" 7); rc3=$?
  local lines3; lines3=$(sc_log_lines)
  SC_BYPASS=""
  # control: the same launch with a readable label goes through (empty log) and is counted
  rm -f "$SC_D/labels-fail"
  local rc2; sc_launch "$SC_RA" 7 >/dev/null; rc2=$?
  local lines2; lines2=$(sc_log_lines)
  sc_cleanup
  assert_ne "$rc" "0" "label read failed: refused" || return 1
  assert_eq "$n" "0" "label read failed: no process (fail closed)" || return 1
  assert_not_contains "$calls" "issue comment" "label read failed: no claim comment" || return 1
  assert_contains "$out" "route=sentry-launch-cap" "tagged line: route" || return 1
  assert_contains "$out" "release=" "tagged line: release" || return 1
  assert_contains "$out" "environment=" "tagged line: environment" || return 1
  assert_contains "$alert" "hooks.example.test" "alert sent" || return 1
  assert_contains "$alert" "route=sentry-launch-cap" "alert payload: route tag" || return 1
  assert_not_contains "$out$alert$ev" "ghp_SECRET" "no gh error text (token) in the line, the alert or the events row" || return 1
  assert_not_contains "$out$alert$ev" "Bad credentials" "no command output at all" || return 1
  assert_eq "$rc3" "0" "SENTRY_CAP_BYPASS=1: launched despite the failed label read" || return 1
  assert_contains "$out3" "launched orchestrator for $SC_A#7" "SENTRY_CAP_BYPASS=1: launched" || return 1
  assert_eq "$lines3" "0" "SENTRY_CAP_BYPASS=1 with unknown labels: not counted" || return 1
  assert_eq "$rc2" "0" "control: with a readable label the launch goes through" || return 1
  assert_eq "$lines2" "1" "control: and is counted" || return 1
}

# ------------------------------------------------------------------------------------------ review of PR #683: releases

test_sc_count_released_line_cancels_the_latest_launch_of_its_ticket() {
  sc_env; local now a b
  now=$(date +%s)
  { printf '%s %s 11\n' "$((now - 500))" "$SC_A"            # launched, stands
    printf '%s %s 12\n' "$((now - 400))" "$SC_A"            # queued ...
    printf '%s %s 12 released\n' "$((now - 300))" "$SC_A"   # ... and dropped before it started
    printf '%s %s 12\n' "$((now - 200))" "$SC_A"            # launched again later: counts
    printf '%s %s 13 released\n' "$((now - 100))" "$SC_A"   # a release with no launch cancels nothing
    printf '%s %s 11 released\n' "$((now - 50))" "$SC_B"    # another repo's release does not touch repo A
    printf '%s %s 14 dropped\n' "$((now - 10))" "$SC_A"; } > "$SC_LOG"   # an unknown 4th field is not a line at all
  a=$(sc_lib "sentry_launch_count $SC_A"); b=$(sc_lib "sentry_launch_count $SC_B")
  sc_cleanup
  assert_eq "$a" "2" "repo A: #11 and the second launch of #12 (hand count: 3 launches - 1 release)" || return 1
  assert_eq "$b" "0" "repo B: nothing launched" || return 1
}

test_sc_slot_release_appends_only_for_a_counted_queue_entry() {
  sc_env; sc_seed "$SC_A" 60
  printf '{"issue":"900","repo":"/x","reason":"queued","sentry_slot":"%s"}' "$SC_A" > "$SC_PIPE/queue/orch-a.json"
  printf '{"issue":"7","repo":"/x","reason":"queued"}' > "$SC_PIPE/queue/orch-b.json"
  printf '{"issue":"8","repo":"/x","reason":"queued","sentry_slot":"evil/repo; rm -rf x"}' > "$SC_PIPE/queue/orch-c.json"
  : > "$SC_PIPE/queue/orch-d.json"
  local before after n last first
  before=$(cat "$SC_LOG")
  sc_lib "sentry_slot_release '$SC_PIPE/queue/orch-b.json'; sentry_slot_release '$SC_PIPE/queue/orch-c.json'; sentry_slot_release '$SC_PIPE/queue/orch-d.json'; sentry_slot_release '$SC_PIPE/queue/missing.json'"
  n=$(sc_log_lines)
  sc_lib "sentry_slot_release '$SC_PIPE/queue/orch-a.json'"
  after=$(sc_log_lines); last=$(tail -1 "$SC_LOG"); first=$(sed -n 1p "$SC_LOG")
  local c; c=$(sc_lib "sentry_launch_count $SC_A")
  sc_cleanup
  assert_eq "$n" "1" "an entry without a valid sentry_slot (or no entry) releases nothing" || return 1
  assert_eq "$after" "2" "the counted entry appends one line" || return 1
  assert_eq "$first" "$before" "the launch line itself is untouched (append-only)" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_A 900 released\$" || { fail "release line shape, got: $last"; return 1; }
  assert_eq "$c" "0" "the place is free again" || return 1
}

test_sc_orch_stop_of_a_queued_launch_releases_its_place() {
  sc_env 'MAX_CONCURRENT=0' 'SENTRY_AUTO_GO_DAILY_CAP=1'
  sc_issue 7 "$SC_A" agent-go sentry-auto-go; sc_issue 8 "$SC_A" agent-go sentry-auto-go
  sc_launch "$SC_RA" 7 >/dev/null
  local c1; c1=$(sc_lib "sentry_launch_count $SC_A")
  HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" /bin/bash "$ORCH_SC" stop "$SC_A#7" >/dev/null 2>&1
  local c2 q=absent; c2=$(sc_lib "sentry_launch_count $SC_A"); ls "$SC_PIPE"/queue/*.json >/dev/null 2>&1 && q=present
  local rc8; sc_launch "$SC_RA" 8 >/dev/null; rc8=$?
  sc_cleanup
  assert_eq "$c1" "1" "control: the queued launch holds the one place" || return 1
  assert_eq "$q" "absent" "control: stop removed the queue entry" || return 1
  assert_eq "$c2" "0" "stop of a launch that never started releases its place" || return 1
  assert_eq "$rc8" "0" "the next ticket is accepted (cap 1)" || return 1
}

test_sc_orch_relaunch_of_a_queued_launch_counts_once() {
  # queued (counted), then launched by hand once a slot is free: the queued place is released, the launch counts itself
  sc_env 'MAX_CONCURRENT=0'
  sc_issue 7 "$SC_A" agent-go sentry-auto-go
  sc_launch "$SC_RA" 7 >/dev/null
  sed -i.bak 's/^MAX_CONCURRENT=0$/MAX_CONCURRENT=3/' "$SC_HOME/.claude/pipeline/config.local.sh"
  local out rc; out=$(sc_launch "$SC_RA" 7 --force); rc=$?   # --force: the queued launch already put agent-in-progress on
  local c n lines; c=$(sc_lib "sentry_launch_count $SC_A"); n=$(sc_orch_launches); lines=$(sc_log_lines)
  sc_cleanup
  assert_eq "$rc" "0" "the hand launch goes through" || return 1
  assert_eq "$n" "1" "one orchestrator process" || return 1
  assert_eq "$lines" "3" "launch, release, launch: three appended lines" || return 1
  assert_eq "$c" "1" "one ticket, one place" || return 1
}

# ------------------------------------------------------------------------------------------ review of PR #683: the lock

test_sc_lock_is_exclusive_per_repo_and_released_by_its_holder_only() {
  sc_env; local held other free foreign hp
  # the holder is a live process other than the one asking
  /bin/sleep 60 & hp=$!
  mkdir "$SC_PIPE/sentry-cap-project-a_repo-a.lock"; echo "$hp $(date +%s)" > "$SC_PIPE/sentry-cap-project-a_repo-a.lock/owner"
  held=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock $SC_A; echo rc=\$?")
  other=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock $SC_B; echo rc=\$?; sentry_cap_unlock; [ -d '$SC_PIPE/sentry-cap-project-b_repo-b.lock' ] && echo left || echo gone")
  # unlock from a process that does not hold it must leave it alone
  foreign=$(sc_lib "SENTRY_CAP_LOCK='$SC_PIPE/sentry-cap-project-a_repo-a.lock'; sentry_cap_unlock; [ -d '$SC_PIPE/sentry-cap-project-a_repo-a.lock' ] && echo left || echo gone")
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  rm -rf "$SC_PIPE/sentry-cap-project-a_repo-a.lock"
  free=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock Project-A/Repo-A; echo rc=\$?; cut -d' ' -f1 \"\$SENTRY_CAP_LOCK/owner\" | grep -c '^[0-9][0-9]*\$'")
  sc_cleanup
  assert_eq "$held" "rc=1" "a lock held by a live process is not taken: the wait times out" || return 1
  assert_eq "$(printf '%s' "$other" | tr '\n' ' ')" "rc=0 gone" "another repo's lock is independent, and unlock removes one's own lock" || return 1
  assert_eq "$foreign" "left" "unlock never removes a lock another process holds" || return 1
  assert_eq "$(printf '%s' "$free" | tr '\n' ' ')" "rc=0 1" "once released it is acquired (repo name case-insensitive) and names its holder" || return 1
}

test_sc_lock_of_a_dead_or_stale_holder_is_taken_over() {
  sc_env; local dead stale young p=99999
  while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done   # a pid with no process
  mkdir "$SC_PIPE/sentry-cap-project-a_repo-a.lock"; echo "$p $(date +%s)" > "$SC_PIPE/sentry-cap-project-a_repo-a.lock/owner"
  dead=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock $SC_A; echo rc=\$?")
  rm -rf "$SC_PIPE/sentry-cap-project-a_repo-a.lock"
  # a live holder (this shell) whose lock is 700 s old: older than the 600 s default
  mkdir "$SC_PIPE/sentry-cap-project-a_repo-a.lock"; echo "$$ $(( $(date +%s) - 700 ))" > "$SC_PIPE/sentry-cap-project-a_repo-a.lock/owner"
  stale=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock $SC_A; echo rc=\$?")
  rm -rf "$SC_PIPE/sentry-cap-project-a_repo-a.lock"
  # control: the same live holder at 500 s is still inside the window
  mkdir "$SC_PIPE/sentry-cap-project-a_repo-a.lock"; echo "$$ $(( $(date +%s) - 500 ))" > "$SC_PIPE/sentry-cap-project-a_repo-a.lock/owner"
  young=$(SENTRY_CAP_LOCK_WAIT_SECS=1 sc_lib "sentry_cap_lock $SC_A; echo rc=\$?")
  sc_cleanup
  assert_eq "$dead" "rc=0" "a lock whose holder process is gone is taken over" || return 1
  assert_eq "$stale" "rc=0" "a lock older than the stale age is taken over" || return 1
  assert_eq "$young" "rc=1" "control: a live holder inside the stale age keeps it" || return 1
}

test_sc_orch_two_launchers_cannot_both_take_the_last_place() {
  # 2 of 3 used; two hand launches of two tickets start together. Each waits the claim settle time (2 s) between its
  # gate and its append, so without the lock both would read 2 and both would launch.
  sc_env 'CLAIM_SETTLE_SECS=2'; sc_seed "$SC_A" 600 1800
  sc_issue 7 "$SC_A" agent-go sentry-auto-go; sc_issue 8 "$SC_A" agent-go sentry-auto-go
  ( sc_launch "$SC_RA" 7 > "$SC_D/out-7" 2>&1; echo $? > "$SC_D/rc-7" ) &
  local p1=$!
  ( sc_launch "$SC_RA" 8 > "$SC_D/out-8" 2>&1; echo $? > "$SC_D/rc-8" ) &
  local p2=$!
  wait "$p1" "$p2"
  local rcs n c outs locks; rcs=$(cat "$SC_D/rc-7" "$SC_D/rc-8" | sort | tr '\n' ' '); n=$(sc_orch_launches)
  c=$(sc_lib "sentry_launch_count $SC_A"); outs=$(cat "$SC_D/out-7" "$SC_D/out-8")
  locks=$(ls -d "$SC_PIPE"/sentry-cap-*.lock 2>/dev/null | wc -l | tr -d ' ')
  sc_cleanup
  assert_eq "$rcs" "0 3 " "one launcher gets the last place, the other is refused with exit 3" || return 1
  assert_eq "$n" "1" "exactly one orchestrator process" || return 1
  assert_eq "$c" "3" "the window holds 3 launches, not 4" || return 1
  assert_contains "$outs" "sentry launch cap reached for $SC_A (3/3 in 24h)" "the loser sees the full window" || return 1
  assert_eq "$locks" "0" "no lock is left behind" || return 1
}

test_sc_orch_refusals_leave_no_lock_behind() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go sentry-auto-go
  sc_launch "$SC_RA" 7 >/dev/null                      # cap reached (exit 3)
  local l1; l1=$(ls -d "$SC_PIPE"/sentry-cap-*.lock 2>/dev/null | wc -l | tr -d ' ')
  rm -f "$SC_LOG"; mkdir "$SC_LOG"; sc_launch "$SC_RA" 7 >/dev/null   # unreadable log (exit 1)
  local l2; l2=$(ls -d "$SC_PIPE"/sentry-cap-*.lock 2>/dev/null | wc -l | tr -d ' ')
  sc_cleanup
  assert_eq "$l1" "0" "a cap refusal releases the lock" || return 1
  assert_eq "$l2" "0" "a fail-closed refusal releases the lock" || return 1
}

run_test test_sc_labels_sentry_auto_go_on_adds_go_and_sentry_auto_go
run_test test_sc_labels_sentry_auto_go_off_is_proposed_without_the_label
run_test test_sc_labels_other_outputs_never_carry_sentry_auto_go
run_test test_sc_intake_md_leaves_the_label_to_the_supervisor
run_test test_sc_config_defines_the_cap_with_the_worst_case_spend
run_test test_sc_config_cap_is_overridable_in_config_local
run_test test_sc_count_missing_file_is_zero
run_test test_sc_count_is_per_repo_and_inside_the_24h_window
run_test test_sc_count_ignores_malformed_lines_and_repo_case
run_test test_sc_record_appends_one_line_and_keeps_earlier_ones
run_test test_sc_no_script_truncates_or_removes_the_launch_log
run_test test_sc_gate_under_cap_at_cap_and_unreadable
run_test test_sc_orch_full_log_refuses_with_exit_3_and_touches_nothing
run_test test_sc_orch_force_does_not_bypass_the_cap
run_test test_sc_orch_bypass_env_launches_and_records
run_test test_sc_orch_bypass_only_on_exactly_one
run_test test_sc_orch_hand_released_sentry_ticket_is_never_throttled
run_test test_sc_orch_under_cap_launches_and_appends_after_the_launch
run_test test_sc_orch_lost_claim_appends_nothing
run_test test_sc_orch_queued_launch_takes_its_slot_at_queue_time
run_test test_sc_orch_label_flag_from_the_supervisor_skips_the_label_read
run_test test_sc_orch_unreadable_launch_log_fails_closed_tagged_and_alerted
run_test test_sc_orch_failed_label_read_fails_closed_tagged_and_alerted
run_test test_sc_count_released_line_cancels_the_latest_launch_of_its_ticket
run_test test_sc_slot_release_appends_only_for_a_counted_queue_entry
run_test test_sc_orch_stop_of_a_queued_launch_releases_its_place
run_test test_sc_orch_relaunch_of_a_queued_launch_counts_once
run_test test_sc_lock_is_exclusive_per_repo_and_released_by_its_holder_only
run_test test_sc_lock_of_a_dead_or_stale_holder_is_taken_over
run_test test_sc_orch_two_launchers_cannot_both_take_the_last_place
run_test test_sc_orch_refusals_leave_no_lock_behind
