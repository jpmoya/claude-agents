# Issue #135 AC9-AC11 — pipeline-report.sh. Hand-written sessions.jsonl rows (F9), a fake `gh` (F10).
# Placeholder names only (public repo). Expected numbers are hand arithmetic, written in comments.

HERE_PR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PR_SH="$HERE_PR/../pipeline-report.sh"
ROOT_PR=$(cd "$HERE_PR/../../.." && pwd)

# pr_row <session_id> <agent|null> <repo|null> <issue|null> <start_ts> <cost|null> <in> <cr> <cc> <tools> <models-json>
pr_row() {
  jq -nc --arg sid "$1" --arg ag "$2" --arg repo "$3" --arg iss "$4" --arg ts "$5" --arg cost "$6" \
    --argjson in "$7" --argjson cr "$8" --argjson cc "$9" --argjson tools "${10}" --argjson models "${11}" '
    {v:1,host:"vm",session_id:$sid,project:"-home-x-app",
     agent:(if $ag=="null" then null else $ag end),
     repo:(if $repo=="null" then null else $repo end),
     issue:(if $iss=="null" then null else ($iss|tonumber) end),
     start_ts:$ts,end_ts:$ts,
     cost_usd:(if $cost=="null" then null else ($cost|tonumber) end),api_s:1,
     in_tok:$in,out_tok:1,cache_read:$cr,cache_create:$cc,tokens_source:"cost-state",cache_hit:null,
     models:$models,tool_calls:$tools}'
}
pr_m() { jq -nc --arg m "$1" --argjson c "$2" '{($m):{cost_usd:$c,in_tok:0,out_tok:0,cache_read:0,cache_create:0}}'; }

pr_setup() {
  PR_T=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-pr.XXXXXX")
  mkdir -p "$PR_T/agents" "$PR_T/home"
  printf -- '---\nname: code-reviewer\nmodel: sonnet\n---\nbody\n' > "$PR_T/agents/code-reviewer.md"
  printf -- '---\nname: orchestrator\nmodel: opus\n---\nbody\n' > "$PR_T/agents/orchestrator.md"
  printf -- '---\nname: fullstack-developer\n---\nbody\n' > "$PR_T/agents/fullstack-developer.md"   # no model: line
  S="claude-sonnet-5"; O="claude-opus-5"
  # F9 — window starts 2026-09-25. Rows:
  #  R1 code-reviewer  a/app#12 10-01 $1.00 in10 cr800 cc100 tools10 models sonnet .60 + opus .40
  #  R2 code-reviewer  a/app#12 10-01 $2.00 in10 cr100 cc100 tools20 models sonnet 2.00
  #  R3 orchestrator   a/app#13 10-01 $4.00 zeros          tools5  models opus 4.00
  #  R4 fullstack-dev  a/app#13 10-01 $0.50 zeros          tools3  models opus 0.50  (no model: line -> not counted)
  #  R5 null agent, no ticket   10-01 $0.25 zeros          tools1  models sonnet .25
  #  R6 code-reviewer  a/app#12 09-01 $100  huge, opus 99  (older than --since -> excluded)
  {
    pr_row r1 code-reviewer project-a/app 12 2026-10-01T10:00:00Z 1.00 10 800 100 10 "$(jq -nc --arg s $S --arg o $O '{($s):{cost_usd:0.6,in_tok:0,out_tok:0,cache_read:0,cache_create:0},($o):{cost_usd:0.4,in_tok:0,out_tok:0,cache_read:0,cache_create:0}}')"
    pr_row r2 code-reviewer project-a/app 12 2026-10-01T11:00:00Z 2.00 10 100 100 20 "$(pr_m $S 2.00)"
    pr_row r3 orchestrator project-a/app 13 2026-10-01T12:00:00Z 4.00 0 0 0 5 "$(pr_m $O 4.00)"
    pr_row r4 fullstack-developer project-a/app 13 2026-10-01T13:00:00Z 0.50 0 0 0 3 "$(pr_m $O 0.50)"
    pr_row r5 null null null 2026-10-01T14:00:00Z 0.25 0 0 0 1 "$(pr_m $S 0.25)"
    pr_row r6 code-reviewer project-a/app 12 2026-09-01T10:00:00Z 100.00 9999 9999 9999 999 "$(pr_m $O 99.00)"
  } > "$PR_T/sessions.jsonl"
}
pr_teardown() { rm -rf "$PR_T"; }

# pr_run <args...> — runs the report with an isolated HOME; sets PR_OUT, PR_RC
pr_run() { PR_OUT=$(HOME="$PR_T/home" "$PR_SH" "$@" 2>/dev/null); PR_RC=$?; }
pr_norm() { printf '%s\n' "$PR_OUT" | sed 's/\$//g' | tr -s ' \t' ' '; }   # strip $ and collapse blanks

PR_HEADS='COST BY AGENT|TOP 5 TICKETS BY COST|CACHE HIT|COST BY MODEL|OPUS IN NON-OPUS AGENTS|GITHUB TRAILS'
# pr_section <heading> — body lines between this heading and the next known heading
pr_section() {
  pr_norm | awk -v h="$1" -v heads="$PR_HEADS" '
    BEGIN { n = split(heads, H, "|") }
    { isH = 0; for (i = 1; i <= n; i++) if (index($0, H[i]) == 1 || index($0, " " H[i]) == 1) isH = 1 }
    isH { on = (index($0, h) > 0); next }
    on { print }'
}

test_pr_ac9_sections_present_in_order() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local r=0 prev=0 h ln
  assert_exit0 "$PR_RC" "AC9 exit" || r=1
  for h in 'COST BY AGENT' 'TOP 5 TICKETS BY COST' 'CACHE HIT' 'COST BY MODEL' 'OPUS IN NON-OPUS AGENTS'; do
    ln=$(printf '%s\n' "$PR_OUT" | grep -n -F "$h" | head -1 | cut -d: -f1)
    [ -n "$ln" ] || { fail "AC9: heading [$h] missing"; r=1; continue; }
    [ "$ln" -gt "$prev" ] || { fail "AC9: heading [$h] out of order"; r=1; }
    prev=$ln
  done
  assert_not_contains "$PR_OUT" "GITHUB TRAILS" "AC9 --no-gh skips the trails section" || r=1
  pr_teardown; return $r
}

test_pr_ac9_cost_by_agent_numbers() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'COST BY AGENT') r=0
  # columns: agent sessions cost cost-per-session tool-calls
  assert_contains "$sec" "code-reviewer 2 3.00 1.50 30" "code-reviewer: 2 sessions, 1+2=3.00, 1.50 each, 10+20 tools (R6 excluded)" || r=1
  assert_contains "$sec" "orchestrator 1 4.00 4.00 5" "orchestrator row" || r=1
  assert_contains "$sec" "fullstack-developer 1 0.50 0.50 3" "fullstack-developer row" || r=1
  assert_contains "$sec" "(interactive) 1 0.25 0.25 1" "null-agent session shown as (interactive)" || r=1
  assert_not_contains "$sec" "100.00" "row older than --since excluded" || r=1
  pr_teardown; return $r
}

test_pr_ac9_top_tickets_and_unattributed() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'TOP 5 TICKETS BY COST') r=0
  assert_contains "$sec" "project-a/app#13 4.50 2" "#13 = 4.00+0.50, 2 sessions" || r=1
  assert_contains "$sec" "project-a/app#12 3.00 2" "#12 = 1.00+2.00, 2 sessions" || r=1
  local l13 l12
  l13=$(printf '%s\n' "$sec" | grep -n 'app#13' | head -1 | cut -d: -f1); l12=$(printf '%s\n' "$sec" | grep -n 'app#12' | head -1 | cut -d: -f1)
  [ -n "$l13" ] && [ -n "$l12" ] && [ "$l13" -lt "$l12" ] || { fail "tickets sorted by cost desc (#13 before #12)"; r=1; }
  assert_contains "$sec" "unattributed: 1 sessions, 0.25" "unattributed line" || r=1
  pr_teardown; return $r
}

test_pr_top5_limits_to_five_tickets() {
  pr_setup
  local i
  { for i in 1 2 3 4 5 6; do pr_row "t$i" orchestrator project-a/app "$((20 + i))" 2026-10-01T10:00:00Z "$i.00" 0 0 0 1 "$(pr_m $S $i.00)"; done; } > "$PR_T/six.jsonl"
  pr_run --no-gh --sessions "$PR_T/six.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'TOP 5 TICKETS BY COST') r=0
  assert_contains "$sec" "project-a/app#26 6.00 1" "most expensive shown" || r=1
  assert_contains "$sec" "project-a/app#22 2.00 1" "5th shown" || r=1
  assert_not_contains "$sec" "project-a/app#21" "6th (cheapest, \$1.00) cut" || r=1
  pr_teardown; return $r
}

test_pr_ac9_cache_hit_rate() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'CACHE HIT')
  # in = 10+10 = 20, cr = 800+100 = 900, cc = 100+100 = 200 → 900/(900+200+20) = 0.80357
  case "$sec" in *0.804*|*80.4*) ;; *) fail "CACHE HIT expected 0.804 or 80.4%, got: $sec"; pr_teardown; return 1;; esac
  pr_teardown
}

test_pr_ac9_cost_by_model() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'COST BY MODEL') r=0
  # sonnet 0.60+2.00+0.25 = 2.85 ; opus 0.40+4.00+0.50 = 4.90
  assert_contains "$sec" "claude-sonnet-5 2.85" "sonnet total" || r=1
  assert_contains "$sec" "claude-opus-5 4.90" "opus total" || r=1
  pr_teardown; return $r
}

test_pr_ac9_opus_in_non_opus_agents() {
  pr_setup; pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'OPUS IN NON-OPUS AGENTS')
  # only R1's opus 0.40 (code-reviewer model: sonnet). Orchestrator is opus; fullstack-developer has no model: line.
  case "$sec" in *0.40*) ;; *) fail "OPUS IN NON-OPUS AGENTS expected 0.40, got: $sec"; pr_teardown; return 1;; esac
  assert_not_contains "$sec" "4.40" "orchestrator opus not counted" || { pr_teardown; return 1; }
  assert_not_contains "$sec" "0.90" "agent without model: line not counted" || { pr_teardown; return 1; }
  pr_teardown
}

test_pr_ac9_two_sessions_files_dedupe_overlap_both_orders() {
  pr_setup
  # second file: r1 again but cost-less (must lose to the row with cost) plus a brand-new session
  { pr_row r1 code-reviewer project-a/app 12 2026-10-01T10:00:00Z null 10 800 100 10 '{}'
    pr_row r7 orchestrator project-a/app 14 2026-10-01T15:00:00Z 1.00 0 0 0 2 "$(pr_m $O 1.00)"
  } > "$PR_T/other.jsonl"
  local r=0 order sec
  for order in "ab" "ba"; do
    if [ "$order" = ab ]; then pr_run --no-gh --sessions "$PR_T/sessions.jsonl" --sessions "$PR_T/other.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
    else pr_run --no-gh --sessions "$PR_T/other.jsonl" --sessions "$PR_T/sessions.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"; fi
    sec=$(pr_section 'COST BY AGENT')
    assert_contains "$sec" "code-reviewer 2 3.00 1.50 30" "[$order] overlapping r1 counted once, cost row wins" || r=1
    assert_contains "$sec" "orchestrator 2 5.00 2.50 7" "[$order] new session from 2nd file merged (4.00+1.00, 5+2 tools)" || r=1
  done
  pr_teardown; return $r
}

test_pr_default_window_is_seven_days() {
  pr_setup
  local d1 d30
  d1=$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  d30=$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  { pr_row new orchestrator project-a/app 30 "$d1" 7.00 0 0 0 1 '{}'
    pr_row old orchestrator project-a/app 31 "$d30" 9.00 0 0 0 1 '{}'; } > "$PR_T/w.jsonl"
  pr_run --no-gh --sessions "$PR_T/w.jsonl" --agents-dir "$PR_T/agents"
  local sec; sec=$(pr_section 'COST BY AGENT') r=0
  assert_contains "$sec" "orchestrator 1 7.00 7.00 1" "1-day-old row in, 30-day-old row out" || r=1
  pr_teardown; return $r
}

test_pr_since_boundary_is_inclusive() {
  pr_setup
  { pr_row edge orchestrator project-a/app 40 2026-09-25T00:00:00Z 3.00 0 0 0 1 '{}'
    pr_row before orchestrator project-a/app 41 2026-09-24T23:59:59Z 8.00 0 0 0 1 '{}'; } > "$PR_T/e.jsonl"
  pr_run --no-gh --sessions "$PR_T/e.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents"
  assert_contains "$(pr_section 'COST BY AGENT')" "orchestrator 1 3.00 3.00 1" "start_ts on --since date is in, a second earlier is out" || { pr_teardown; return 1; }
  pr_teardown
}

# ---- F10: GITHUB TRAILS ------------------------------------------------------------------------
# Fake gh handles only `gh api repos/<repo>/issues/<N>/comments?per_page=100 --paginate [--jq expr]`,
# applying --jq per page like the real one. Ticket 12: first-pass. Ticket 13: 2x IMPLEMENTED, FAIL, BLOCKED, DEPLOYED.
# Ticket 14: gh exits 1.
pr_gh_setup() {
  mkdir -p "$PR_T/bin" "$PR_T/pages"
  : > "$PR_T/gh-calls.log"
  cat > "$PR_T/bin/gh" <<EOF
#!/bin/bash
D="$PR_T"
printf '%s\n' "\$*" >> "\$D/gh-calls.log"
[ "\$1" = "api" ] || { echo "fake gh: unsupported: \$*" >&2; exit 1; }
path=\$2; expr=""
while [ \$# -gt 0 ]; do case "\$1" in --jq|-q) expr=\$2; shift ;; esac; shift; done
n=\$(printf '%s' "\$path" | sed -n 's#.*issues/\([0-9][0-9]*\)/comments.*#\1#p')
[ -n "\$n" ] && [ -f "\$D/pages/\$n.json" ] || exit 1
if [ -n "\$expr" ]; then jq -r "\$expr" "\$D/pages/\$n.json" || exit 1; else cat "\$D/pages/\$n.json"; fi
EOF
  chmod +x "$PR_T/bin/gh"
  pr_c() { jq -n --arg b "$1" '{created_at:"2026-10-01T10:00:00Z",user:{login:"jpmoya"},body:$b}'; }
  {
    pr_c '**[fullstack-developer] IMPLEMENTED**
done'
    pr_c '**[deployer] NOTE**
will report DEPLOYED soon
**[fullstack-developer] IMPLEMENTED**'   # second-line text: not a marker
    pr_c '**[code-reviewer] PASS**
ok'
    pr_c '**[deployer] DEPLOYED**
shipped'
  } | jq -s . > "$PR_T/pages/12.json"
  {
    pr_c '**[fullstack-developer] IMPLEMENTED**
v1'
    pr_c '**[code-reviewer] FAIL: 2 findings**
fix'
    pr_c '**[fullstack-developer] IMPLEMENTED**
v2'
    pr_c '**[deployer] BLOCKED**
conflict'
    pr_c '**[deployer] DEPLOYED**
shipped'
  } | jq -s . > "$PR_T/pages/13.json"
  # 14: no page file → fake gh exits 1
  { pr_row g1 orchestrator project-a/app 12 2026-10-01T10:00:00Z 1.00 0 0 0 1 '{}'
    pr_row g2 orchestrator project-a/app 13 2026-10-01T11:00:00Z 1.00 0 0 0 1 '{}'
    pr_row g3 orchestrator project-a/app 14 2026-10-01T12:00:00Z 1.00 0 0 0 1 '{}'
    pr_row g4 orchestrator project-a/app 12 2026-10-01T13:00:00Z 1.00 0 0 0 1 '{}'   # same ticket twice: one read
  } > "$PR_T/g.jsonl"
}

pr_run_gh() { PR_OUT=$(HOME="$PR_T/home" PATH="$PR_T/bin:$PATH" "$PR_SH" --sessions "$PR_T/g.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents" 2>/dev/null); PR_RC=$?; }

test_pr_ac10_github_trails_numbers() {
  pr_setup; pr_gh_setup; pr_run_gh
  local r=0 sec; sec=$(pr_section 'GITHUB TRAILS')
  assert_exit0 "$PR_RC" "AC10 exit 0 even though one ticket could not be read" || r=1
  assert_ne "$sec" "" "AC10 GITHUB TRAILS section present" || r=1
  printf '%s\n' "$sec" | grep -i 'deployed' | grep -v -i 'first-pass\|blocked' | grep -q '2' || { fail "AC10 tickets deployed: 2 in: $sec"; r=1; }
  printf '%s\n' "$sec" | grep -i 'first-pass' | grep -q '1 of 2 (50%)' || { fail "AC10 first-pass 1 of 2 (50%) in: $sec"; r=1; }
  printf '%s\n' "$sec" | grep -i 'blocked' | grep -q '1 of 3' || { fail "AC10 deployer-BLOCKED 1 of 3 in: $sec"; r=1; }
  printf '%s\n' "$sec" | grep 'IMPLEMENTED' | grep -q '1' || { fail "AC10 tickets with 2+ IMPLEMENTED: 1 in: $sec"; r=1; }
  assert_contains "$sec" "could not read: 1" "AC10 failed read counted" || r=1
  pr_teardown; return $r
}

test_pr_github_trails_one_rest_read_per_ticket() {
  pr_setup; pr_gh_setup; pr_run_gh
  local r=0
  assert_eq "$(grep -c 'issues/12/comments' "$PR_T/gh-calls.log")" "1" "ticket 12 read once" || r=1
  assert_eq "$(grep -c 'issues/13/comments' "$PR_T/gh-calls.log")" "1" "ticket 13 read once" || r=1
  assert_eq "$(wc -l < "$PR_T/gh-calls.log" | tr -d ' ')" "3" "exactly 3 gh calls, all REST (no GraphQL / issue view)" || r=1
  assert_contains "$(cat "$PR_T/gh-calls.log")" "repos/project-a/app/issues/12/comments?per_page=100" "REST path" || r=1
  assert_contains "$(cat "$PR_T/gh-calls.log")" "--paginate" "paginated" || r=1
  pr_teardown; return $r
}

test_pr_no_gh_flag_makes_zero_gh_calls() {
  pr_setup; pr_gh_setup
  PR_OUT=$(HOME="$PR_T/home" PATH="$PR_T/bin:$PATH" "$PR_SH" --no-gh --sessions "$PR_T/g.jsonl" --since 2026-09-25 --agents-dir "$PR_T/agents" 2>/dev/null); PR_RC=$?
  local r=0
  assert_exit0 "$PR_RC" "exit" || r=1
  assert_contains "$PR_OUT" "COST BY AGENT" "report still printed" || r=1
  assert_eq "$(wc -l < "$PR_T/gh-calls.log" | tr -d ' ')" "0" "--no-gh: gh never called" || r=1
  pr_teardown; return $r
}

test_pr_ac11_never_reads_runs_jsonl() {
  assert_eq "$(grep -c 'runs\.jsonl' "$PR_SH")" "0" "AC11 no reference to runs.jsonl" || return 1
  # a stub that merely prints NotImplemented would trivially satisfy the grep: also require it to work
  local d out rc; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-pr.XXXXXX"); : > "$d/empty.jsonl"
  out=$(HOME="$d" "$PR_SH" --no-gh --sessions "$d/empty.jsonl" --agents-dir "$d" 2>/dev/null); rc=$?
  rm -rf "$d"
  assert_exit0 "$rc" "AC11 report runs on an empty sessions file" || return 1
  assert_contains "$out" "COST BY AGENT" "AC11 report prints" || return 1
}

for t in test_pr_ac9_sections_present_in_order test_pr_ac9_cost_by_agent_numbers test_pr_ac9_top_tickets_and_unattributed \
  test_pr_top5_limits_to_five_tickets test_pr_ac9_cache_hit_rate test_pr_ac9_cost_by_model test_pr_ac9_opus_in_non_opus_agents \
  test_pr_ac9_two_sessions_files_dedupe_overlap_both_orders test_pr_default_window_is_seven_days test_pr_since_boundary_is_inclusive \
  test_pr_ac10_github_trails_numbers test_pr_github_trails_one_rest_read_per_ticket test_pr_no_gh_flag_makes_zero_gh_calls \
  test_pr_ac11_never_reads_runs_jsonl; do
  run_test "$t"
done
