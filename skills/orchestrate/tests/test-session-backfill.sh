# Issue #135 AC1-AC8a, AC11-ish — session-backfill.sh. Synthetic fixtures only (public repo): placeholder
# names (project-a/app, issue 12). Every case runs in a mktemp -d tree with an isolated HOME; nothing
# touches ~/.claude/projects or ~/logs.
#
# CONTRACT ASSUMPTION (ticket leaves the name open): the lock is the directory "<--out>.lock"
# (i.e. sessions.jsonl.lock) and the owner's pid is stored in the file "<lock>/pid".

HERE_SB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SB="$HERE_SB/../session-backfill.sh"
LIB_SB="$HERE_SB/../pipeline-lib.sh"

F1_ID=aaaaaaaa-0000-0000-0000-000000000001
F2_ID=aaaaaaaa-0000-0000-0000-000000000002
F3_ID=aaaaaaaa-0000-0000-0000-000000000003
F5_ID=aaaaaaaa-0000-0000-0000-000000000005
F8X_ID=aaaaaaaa-0000-0000-0000-000000000008

sb_setup() {  # sets SB_T (tree), HOME (isolated), SB_OUT
  SB_T=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sb.XXXXXX")
  SB_HOME="$SB_T/home"   # passed per-run to the script; the runner shell's own HOME is never changed
  mkdir -p "$SB_HOME/logs/pipeline" "$SB_T/src1/-home-x-app" "$SB_T/src2/-home-x-app"
  SB_OUT="$SB_T/out/sessions.jsonl"
  mkdir -p "$SB_T/out"
}

sb_age() {  # sb_age <file> <minutes-ago> — portable mtime set
  python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))" "$1" "$2"
}

# F1 body without the cost-state line.
sb_f1_lines() {
  jq -nc '{type:"agent-setting",agentSetting:"code-reviewer",sessionId:"s1"}'
  jq -nc '{type:"user",timestamp:"2026-10-01T23:03:16Z",message:{content:"Review PR. Repo: project-a/app. Issue: #12."}}'
  # usage sums: in 30, out 300, cache_read 3000, cache_create 150 — deliberately != modelUsage sums
  jq -nc '{type:"assistant",timestamp:"2026-10-01T23:05:00Z",message:{id:"m1",model:"claude-sonnet-5",usage:{input_tokens:10,output_tokens:100,cache_read_input_tokens:1000,cache_creation_input_tokens:50},content:[{type:"tool_use",id:"t1"},{type:"tool_use",id:"t2"}]}}'
  jq -nc '{type:"assistant",timestamp:"2026-10-01T23:12:56Z",message:{id:"m2",model:"claude-opus-5",usage:{input_tokens:20,output_tokens:200,cache_read_input_tokens:2000,cache_creation_input_tokens:100},content:[{type:"tool_use",id:"t3"}]}}'
}
sb_f1_cost() {
  # sums: in 8+740=748, out 631+19758=20389, cr 60835+5238459=5299294, cc 7380+172350=179730
  jq -nc '{type:"cost-state",sessionId:"s1",totalCostUSD:0.95,totalAPIDuration:225000,modelUsage:{
    "claude-sonnet-5":{inputTokens:8,outputTokens:631,cacheReadInputTokens:60835,cacheCreationInputTokens:7380,costUSD:0.44},
    "claude-opus-5":{inputTokens:740,outputTokens:19758,cacheReadInputTokens:5238459,cacheCreationInputTokens:172350,costUSD:0.51}}}'
}
sb_mk_f1() {  # sb_mk_f1 <srcdir> [nocost]
  local f="$1/-home-x-app/$F1_ID.jsonl"
  { sb_f1_lines; [ "${2:-}" = nocost ] || sb_f1_cost; } > "$f"
}
sb_mk_f2() {
  { jq -nc '{type:"agent-setting",agentSetting:"orchestrator",sessionId:"s2"}'
    jq -nc '{type:"user",timestamp:"2026-10-01T10:00:00Z",message:{content:"Drive project-a/app#12 through the pipeline. Repo: /home/x/app. Read the latest marker and continue."}}'
    jq -nc '{type:"cost-state",sessionId:"s2",totalCostUSD:1.5,totalAPIDuration:1000,modelUsage:{"claude-opus-5":{inputTokens:1,outputTokens:2,cacheReadInputTokens:3,cacheCreationInputTokens:4,costUSD:1.5}}}'
  } > "$1/-home-x-app/$F2_ID.jsonl"
}
sb_mk_f3() {
  { jq -nc '{type:"user",timestamp:"2026-10-01T11:00:00Z",message:{content:"hello, just chatting"}}'
    jq -nc '{type:"cost-state",sessionId:"s3",totalCostUSD:0.1,totalAPIDuration:500,modelUsage:{"claude-sonnet-5":{inputTokens:1,outputTokens:1,cacheReadInputTokens:0,cacheCreationInputTokens:0,costUSD:0.1}}}'
  } > "$1/-home-x-app/$F3_ID.jsonl"
}
sb_mk_f5() {  # killed/running: no cost-state; mk1 appears twice (last line wins), mk2 once
  { jq -nc '{type:"agent-setting",agentSetting:"code-reviewer",sessionId:"s5"}'
    jq -nc '{type:"user",timestamp:"2026-10-01T08:00:00Z",message:{content:"Review PR. Repo: project-a/app. Issue: #12."}}'
    jq -nc '{type:"assistant",timestamp:"2026-10-01T08:01:00Z",message:{id:"mk1",model:"claude-sonnet-5",usage:{input_tokens:5,output_tokens:10,cache_read_input_tokens:100,cache_creation_input_tokens:20},content:[{type:"tool_use",id:"t1"}]}}'
    jq -nc '{type:"assistant",timestamp:"2026-10-01T08:01:05Z",message:{id:"mk1",model:"claude-sonnet-5",usage:{input_tokens:5,output_tokens:50,cache_read_input_tokens:100,cache_creation_input_tokens:20},content:[{type:"tool_use",id:"t1"}]}}'
    jq -nc '{type:"assistant",timestamp:"2026-10-01T08:02:00Z",message:{id:"mk2",model:"claude-sonnet-5",usage:{input_tokens:7,output_tokens:70,cache_read_input_tokens:200,cache_creation_input_tokens:30},content:[{type:"tool_use",id:"t2"}]}}'
  } > "$1/-home-x-app/$F5_ID.jsonl"
}

sb_run() { SB_STDOUT=$(HOME="$SB_HOME" "$SB" "$@" 2>/dev/null); SB_RC=$?; }
sb_rows() { [ -f "$SB_OUT" ] && wc -l < "$SB_OUT" | tr -d ' ' || echo 0; }
sb_row() {  # sb_row <session_id> <jq-expr> — evaluates expr on that session's row
  jq -r --arg id "$1" "select(.session_id==\$id) | $2" "$SB_OUT" 2>/dev/null
}
sb_teardown() { cleanup_running; rm -rf "$SB_T"; }

test_sb_ac1_f1_row_uses_cost_state() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_exit0 "$SB_RC" "AC1 exit" || { sb_teardown; return 1; }
  local r=0
  assert_eq "$(sb_rows)" "1" "AC1 one row" || r=1
  assert_eq "$(sb_row $F1_ID .agent)" "code-reviewer" "AC1 agent" || r=1
  assert_eq "$(sb_row $F1_ID .repo)" "project-a/app" "AC1 repo" || r=1
  assert_eq "$(sb_row $F1_ID .issue)" "12" "AC1 issue" || r=1
  assert_eq "$(sb_row $F1_ID .v)" "1" "AC1 v" || r=1
  assert_eq "$(sb_row $F1_ID .project)" "-home-x-app" "AC1 project slug" || r=1
  assert_eq "$(sb_row $F1_ID .cost_usd)" "0.95" "AC1 cost = totalCostUSD" || r=1
  assert_eq "$(sb_row $F1_ID .api_s)" "225" "AC1 api_s = 225000/1000" || r=1
  assert_eq "$(sb_row $F1_ID .in_tok)" "748" "AC1 in_tok (modelUsage sum, not usage sum 30)" || r=1
  assert_eq "$(sb_row $F1_ID .out_tok)" "20389" "AC1 out_tok" || r=1
  assert_eq "$(sb_row $F1_ID .cache_read)" "5299294" "AC1 cache_read" || r=1
  assert_eq "$(sb_row $F1_ID .cache_create)" "179730" "AC1 cache_create" || r=1
  assert_eq "$(sb_row $F1_ID .tokens_source)" "cost-state" "AC1 tokens_source" || r=1
  assert_eq "$(sb_row $F1_ID .tool_calls)" "3" "AC1 tool_calls (t1,t2,t3)" || r=1
  assert_eq "$(sb_row $F1_ID .start_ts)" "2026-10-01T23:03:16Z" "AC1 start_ts" || r=1
  assert_eq "$(sb_row $F1_ID .end_ts)" "2026-10-01T23:12:56Z" "AC1 end_ts" || r=1
  # hand arithmetic: 5299294 / (5299294 + 179730 + 748) = 5299294/5479772 = 0.96706...
  assert_eq "$(sb_row $F1_ID '(.cache_hit*1000|round)')" "967" "AC1 cache_hit ~0.967" || r=1
  assert_eq "$(sb_row $F1_ID '.models["claude-sonnet-5"].cost_usd')" "0.44" "AC1 models sonnet cost" || r=1
  assert_eq "$(sb_row $F1_ID '.models["claude-opus-5"].cost_usd')" "0.51" "AC1 models opus cost" || r=1
  assert_eq "$(sb_row $F1_ID '.models["claude-sonnet-5"].in_tok')" "8" "AC1 models sonnet in_tok" || r=1
  assert_eq "$(sb_row $F1_ID '.models["claude-opus-5"].cache_create')" "172350" "AC1 models opus cache_create" || r=1
  sb_teardown; return $r
}

test_sb_host_field_matches_pipeline_host() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  local expect; expect=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_row $F1_ID .host)" "$expect" "host = lowercase hostname -s" || r=1
  local fn; fn=$(bash -c ". '$LIB_SB' >/dev/null 2>&1; pipeline_host" 2>/dev/null)
  assert_eq "$fn" "$expect" "pipeline_host() defined in pipeline-lib.sh" || r=1
  sb_teardown; return $r
}

test_sb_ac2_second_run_is_byte_identical() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f2 "$SB_T/src1"; sb_mk_f3 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  [ -f "$SB_OUT" ] || { fail "AC2: first run wrote no output"; sb_teardown; return 1; }
  cp "$SB_OUT" "$SB_T/first"
  local n1; n1=$(sb_rows)
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_rows)" "$n1" "AC2 row count unchanged" || r=1
  assert_eq "$n1" "3" "AC2 three sessions" || r=1
  cmp -s "$SB_T/first" "$SB_OUT" || { fail "AC2: output not byte-identical on second run"; r=1; }
  assert_contains "$SB_STDOUT" "sessions.jsonl: 3 rows (0 added, 0 updated)" "AC2 summary on unchanged input" || r=1
  sb_teardown; return $r
}

test_sb_output_sorted_by_start_ts_then_session_id() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f2 "$SB_T/src1"; sb_mk_f3 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  # start_ts: F2 10:00, F3 11:00, F1 23:03 (2026-10-01) → F2, F3, F1
  assert_eq "$(jq -r .session_id "$SB_OUT" | tr '\n' ' ')" "$F2_ID $F3_ID $F1_ID " "sorted by start_ts" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_summary_line_first_run() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f2 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local last; last=$(printf '%s\n' "$SB_STDOUT" | tail -1)
  assert_eq "$last" "sessions.jsonl: 2 rows (2 added, 0 updated), 0 skipped as recent, 0 malformed lines skipped" "summary last line" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_ac3_f3_unattributable_row_has_null_repo_issue() {
  sb_setup; sb_mk_f3 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "AC3 exit" || r=1
  assert_eq "$(sb_rows)" "1" "AC3 row written, not dropped" || r=1
  assert_eq "$(sb_row $F3_ID .repo)" "null" "AC3 repo null" || r=1
  assert_eq "$(sb_row $F3_ID .issue)" "null" "AC3 issue null" || r=1
  assert_eq "$(sb_row $F3_ID .agent)" "null" "AC3 agent null (no agent-setting)" || r=1
  sb_teardown; return $r
}

test_sb_ac3_f4_malformed_line_skipped_and_counted() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  printf '%s\n' '{"type":"assistant", "mess' >> "$SB_T/src1/-home-x-app/$F1_ID.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "AC3 exit 0 despite bad line" || r=1
  assert_eq "$(sb_rows)" "1" "AC3 one row" || r=1
  assert_eq "$(sb_row $F1_ID .cost_usd)" "0.95" "AC3 row still correct" || r=1
  assert_eq "$(sb_row $F1_ID .tool_calls)" "3" "AC3 tool_calls still correct" || r=1
  assert_contains "$(printf '%s\n' "$SB_STDOUT" | tail -1)" "1 malformed lines skipped" "AC3 summary counts it" || r=1
  sb_teardown; return $r
}

test_sb_ac3_file_without_timestamps_skipped_and_exit0() {
  sb_setup
  printf '%s\n' '{"type":"agent-setting","agentSetting":"x","sessionId":"q"}' > "$SB_T/src1/-home-x-app/bbbbbbbb-0000-0000-0000-000000000009.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT" --min-age-min 0
  local r=0
  assert_exit0 "$SB_RC" "no-timestamp file exit 0" || r=1
  assert_eq "$(sb_rows)" "0" "no-timestamp file yields no row" || r=1
  sb_teardown; return $r
}

test_sb_ac4_orchestrator_prompt_shape() {
  sb_setup; sb_mk_f2 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_row $F2_ID .agent)" "orchestrator" "AC4 agent" || r=1
  assert_eq "$(sb_row $F2_ID .repo)" "project-a/app" "AC4 repo (not /home/x/app)" || r=1
  assert_eq "$(sb_row $F2_ID .issue)" "12" "AC4 issue" || r=1
  sb_teardown; return $r
}

test_sb_rule_a_takes_last_valid_repo_and_issue() {
  sb_setup
  { jq -nc '{type:"user",timestamp:"2026-10-01T12:00:00Z",message:{content:"Repo: project-b/old. Issue: #1. Later: Repo: /abs/path. Repo: project-a/app. Issue: #12."}}'
    jq -nc '{type:"cost-state",sessionId:"s",totalCostUSD:0.1,totalAPIDuration:1,modelUsage:{}}'
  } > "$SB_T/src1/-home-x-app/cccccccc-0000-0000-0000-000000000001.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local id=cccccccc-0000-0000-0000-000000000001 r=0
  assert_eq "$(sb_row $id .repo)" "project-a/app" "last valid Repo wins, absolute path ignored" || r=1
  assert_eq "$(sb_row $id .issue)" "12" "last Issue wins" || r=1
  sb_teardown; return $r
}

test_sb_ac5_f5_killed_session_uses_usage_blocks() {
  sb_setup; sb_mk_f5 "$SB_T/src1"; sb_age "$SB_T/src1/-home-x-app/$F5_ID.jsonl" 120
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_rows)" "1" "AC5 row written for 2h-old killed session" || r=1
  assert_eq "$(sb_row $F5_ID .cost_usd)" "null" "AC5 cost null" || r=1
  assert_eq "$(sb_row $F5_ID .api_s)" "null" "AC5 api_s null" || r=1
  assert_eq "$(sb_row $F5_ID '.models|length')" "0" "AC5 models {}" || r=1
  assert_eq "$(sb_row $F5_ID .tokens_source)" "usage" "AC5 tokens_source" || r=1
  # mk1 counted once via its last line (in 5,out 50,cr 100,cc 20) + mk2 (7,70,200,30)
  assert_eq "$(sb_row $F5_ID .in_tok)" "12" "AC5 in_tok = 5+7" || r=1
  assert_eq "$(sb_row $F5_ID .out_tok)" "120" "AC5 out_tok = 50+70 (mk1 counted once)" || r=1
  assert_eq "$(sb_row $F5_ID .cache_read)" "300" "AC5 cache_read = 100+200" || r=1
  assert_eq "$(sb_row $F5_ID .cache_create)" "50" "AC5 cache_create = 20+30" || r=1
  assert_eq "$(sb_row $F5_ID .tool_calls)" "2" "AC5 distinct tool ids t1,t2" || r=1
  # 300/(300+50+12) = 0.8287
  assert_eq "$(sb_row $F5_ID '(.cache_hit*1000|round)')" "829" "AC5 cache_hit" || r=1
  sb_teardown; return $r
}

test_sb_cache_hit_null_when_denominator_zero() {
  sb_setup
  { jq -nc '{type:"user",timestamp:"2026-10-01T12:00:00Z",message:{content:"x"}}'
    jq -nc '{type:"cost-state",sessionId:"s",totalCostUSD:0,totalAPIDuration:0,modelUsage:{"claude-sonnet-5":{inputTokens:0,outputTokens:5,cacheReadInputTokens:0,cacheCreationInputTokens:0,costUSD:0}}}'
  } > "$SB_T/src1/-home-x-app/dddddddd-0000-0000-0000-000000000001.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_eq "$(sb_row dddddddd-0000-0000-0000-000000000001 .cache_hit)" "null" "cache_hit null on 0 denominator" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_ac5_f6_running_session_skipped_then_picked_up() {
  sb_setup; sb_mk_f5 "$SB_T/src1"   # fresh mtime, no cost-state
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "AC5 exit" || r=1
  assert_eq "$(sb_rows)" "0" "AC5 no row for a fresh cost-less file" || r=1
  assert_contains "$(printf '%s\n' "$SB_STDOUT" | tail -1)" "1 skipped as recent" "AC5 summary counts skip" || r=1
  sb_run --source "$SB_T/src1" --out "$SB_OUT" --min-age-min 0
  assert_eq "$(sb_rows)" "1" "AC5 --min-age-min 0 writes the row" || r=1
  sb_teardown; return $r
}

test_sb_fresh_file_with_cost_state_is_not_skipped() {
  sb_setup; sb_mk_f1 "$SB_T/src1"   # fresh mtime but finished
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_eq "$(sb_rows)" "1" "finished fresh session is written" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_ac5_f7_subagent_files_ignored() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  mkdir -p "$SB_T/src1/-home-x-app/$F1_ID/subagents"
  { jq -nc '{type:"user",timestamp:"2026-10-01T12:00:00Z",message:{content:"sub"}}'
    jq -nc '{type:"cost-state",sessionId:"a1",totalCostUSD:9,totalAPIDuration:1,modelUsage:{}}'
  } > "$SB_T/src1/-home-x-app/$F1_ID/subagents/agent-a1.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_rows)" "1" "AC5 only the session row" || r=1
  assert_eq "$(grep -c 'agent-a1' "$SB_OUT")" "0" "AC5 no agent-a1 row" || r=1
  sb_teardown; return $r
}

test_sb_ac6_two_sources_cost_wins_both_orders() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f1 "$SB_T/src2" nocost
  sb_age "$SB_T/src2/-home-x-app/$F1_ID.jsonl" 300
  { jq -nc '{type:"user",timestamp:"2026-10-01T09:00:00Z",message:{content:"extra"}}'
    jq -nc '{type:"cost-state",sessionId:"x",totalCostUSD:0.2,totalAPIDuration:1,modelUsage:{}}'
  } > "$SB_T/src2/-home-x-app/$F8X_ID.jsonl"
  local r=0 order
  for order in "12" "21"; do
    rm -f "$SB_OUT"
    if [ "$order" = 12 ]; then sb_run --source "$SB_T/src1" --source "$SB_T/src2" --out "$SB_OUT"
    else sb_run --source "$SB_T/src2" --source "$SB_T/src1" --out "$SB_OUT"; fi
    assert_eq "$(sb_rows)" "2" "AC6 [$order] one row per session id" || r=1
    assert_eq "$(sb_row $F1_ID .cost_usd)" "0.95" "AC6 [$order] row with cost wins" || r=1
    assert_eq "$(sb_row $F1_ID .tokens_source)" "cost-state" "AC6 [$order] cost-state source wins" || r=1
  done
  sb_teardown; return $r
}

test_sb_ac6_default_source_is_home_claude_projects() {
  sb_setup
  mkdir -p "$SB_HOME/.claude/projects/-home-x-app"
  sb_mk_f1 "$SB_HOME/.claude/projects"
  sb_run --out "$SB_OUT"
  assert_eq "$(sb_rows)" "1" "AC6 default --source = \$HOME/.claude/projects" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_default_out_is_home_logs_pipeline_sessions_jsonl() {
  sb_setup
  mkdir -p "$SB_HOME/.claude/projects/-home-x-app"
  sb_mk_f1 "$SB_HOME/.claude/projects"
  sb_run
  assert_file_exists "$SB_HOME/logs/pipeline/sessions.jsonl" "default --out" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_ac7_rows_for_vanished_transcripts_are_kept() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f2 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  rm -f "$SB_T/src1/-home-x-app/$F1_ID.jsonl"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_rows)" "2" "AC7 both rows present" || r=1
  assert_eq "$(sb_row $F1_ID .cost_usd)" "0.95" "AC7 vanished session row intact" || r=1
  sb_teardown; return $r
}

test_sb_merge_cost_beats_no_cost_against_existing_out() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  # next run sees only a cost-less copy with a later end_ts: the existing row (has cost) must stay
  sb_mk_f1 "$SB_T/src2" nocost
  printf '%s\n' "$(jq -nc '{type:"assistant",timestamp:"2026-10-02T23:00:00Z",message:{id:"m9",model:"x",usage:{input_tokens:1,output_tokens:1,cache_read_input_tokens:0,cache_creation_input_tokens:0},content:[]}}')" >> "$SB_T/src2/-home-x-app/$F1_ID.jsonl"
  sb_age "$SB_T/src2/-home-x-app/$F1_ID.jsonl" 300
  sb_run --source "$SB_T/src2" --out "$SB_OUT"
  assert_eq "$(sb_row $F1_ID .cost_usd)" "0.95" "cost row beats later cost-less row" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_merge_later_end_ts_wins_when_both_lack_cost() {
  sb_setup; sb_mk_f5 "$SB_T/src1"; sb_age "$SB_T/src1/-home-x-app/$F5_ID.jsonl" 120
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  # session grew: one more assistant message later in the day
  jq -nc '{type:"assistant",timestamp:"2026-10-01T09:00:00Z",message:{id:"mk3",model:"claude-sonnet-5",usage:{input_tokens:1,output_tokens:1,cache_read_input_tokens:0,cache_creation_input_tokens:0},content:[]}}' >> "$SB_T/src1/-home-x-app/$F5_ID.jsonl"
  sb_age "$SB_T/src1/-home-x-app/$F5_ID.jsonl" 120
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_eq "$(sb_row $F5_ID .end_ts)" "2026-10-01T09:00:00Z" "later end_ts wins" || r=1
  assert_eq "$(sb_row $F5_ID .in_tok)" "13" "updated row tokens 12+1" || r=1
  assert_contains "$(printf '%s\n' "$SB_STDOUT" | tail -1)" "(0 added, 1 updated)" "summary counts update" || r=1
  sb_teardown; return $r
}

test_sb_ac8_no_prompt_text_in_output() {
  sb_setup; sb_mk_f1 "$SB_T/src1"; sb_mk_f2 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_file_exists "$SB_OUT" "AC8 output exists" || { sb_teardown; return 1; }
  local r=0
  assert_eq "$(grep -c 'Review PR' "$SB_OUT")" "0" "AC8 no F1 prompt text" || r=1
  assert_eq "$(grep -c 'through the pipeline' "$SB_OUT")" "0" "AC8 no F2 prompt text" || r=1
  sb_teardown; return $r
}

test_sb_never_modifies_transcripts() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  local before; before=$(cksum < "$SB_T/src1/-home-x-app/$F1_ID.jsonl")
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_file_exists "$SB_OUT" "output exists" || { sb_teardown; return 1; }
  assert_eq "$(cksum < "$SB_T/src1/-home-x-app/$F1_ID.jsonl")" "$before" "transcript untouched" || { sb_teardown; return 1; }
  sb_teardown
}

test_sb_ac8a_dead_pid_lock_is_cleared_and_run_completes() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  local p=99999; while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done
  mkdir -p "$SB_OUT.lock"; echo "$p" > "$SB_OUT.lock/pid"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "AC8a exit 0" || r=1
  assert_eq "$(sb_rows)" "1" "AC8a rows written despite stale lock" || r=1
  assert_file_absent "$SB_OUT.lock" "AC8a no lock left behind" || r=1
  case "$SB_STDOUT" in *[Ll]ock*) ;; *) fail "AC8a says it removed the stale lock (stdout mentions lock)"; r=1;; esac # || r=1
  sb_teardown; return $r
}

test_sb_ac8a_live_pid_lock_makes_run_exit_0_untouched() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  printf 'SENTINEL\n' > "$SB_OUT"
  sleep 300 & local lp=$!; RUNNING_PIDS="$RUNNING_PIDS $lp"
  mkdir -p "$SB_OUT.lock"; echo "$lp" > "$SB_OUT.lock/pid"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "AC8a live lock exit 0" || r=1
  assert_eq "$(cat "$SB_OUT")" "SENTINEL" "AC8a output untouched" || r=1
  assert_file_exists "$SB_OUT.lock" "AC8a foreign lock left alone" || r=1
  assert_ne "$SB_STDOUT" "" "AC8a prints a notice" || r=1
  sb_teardown; return $r
}

test_sb_ac8a_lock_older_than_6h_is_cleared_even_with_live_pid() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  sleep 300 & local lp=$!; RUNNING_PIDS="$RUNNING_PIDS $lp"
  mkdir -p "$SB_OUT.lock"; echo "$lp" > "$SB_OUT.lock/pid"
  sb_age "$SB_OUT.lock" 400   # 6h40m
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  local r=0
  assert_exit0 "$SB_RC" "old lock exit 0" || r=1
  assert_eq "$(sb_rows)" "1" "old lock cleared, rows written" || r=1
  assert_file_absent "$SB_OUT.lock" "no lock left" || r=1
  sb_teardown; return $r
}

test_sb_lock_removed_after_normal_run() {
  sb_setup; sb_mk_f1 "$SB_T/src1"
  sb_run --source "$SB_T/src1" --out "$SB_OUT"
  assert_eq "$(sb_rows)" "1" "run wrote a row" || { sb_teardown; return 1; }
  assert_file_absent "$SB_OUT.lock" "lock removed on exit" || { sb_teardown; return 1; }
  sb_teardown
}

for t in test_sb_ac1_f1_row_uses_cost_state test_sb_host_field_matches_pipeline_host \
  test_sb_ac2_second_run_is_byte_identical test_sb_output_sorted_by_start_ts_then_session_id \
  test_sb_summary_line_first_run test_sb_ac3_f3_unattributable_row_has_null_repo_issue \
  test_sb_ac3_f4_malformed_line_skipped_and_counted test_sb_ac3_file_without_timestamps_skipped_and_exit0 \
  test_sb_ac4_orchestrator_prompt_shape test_sb_rule_a_takes_last_valid_repo_and_issue \
  test_sb_ac5_f5_killed_session_uses_usage_blocks test_sb_cache_hit_null_when_denominator_zero \
  test_sb_ac5_f6_running_session_skipped_then_picked_up test_sb_fresh_file_with_cost_state_is_not_skipped \
  test_sb_ac5_f7_subagent_files_ignored test_sb_ac6_two_sources_cost_wins_both_orders \
  test_sb_ac6_default_source_is_home_claude_projects test_sb_default_out_is_home_logs_pipeline_sessions_jsonl \
  test_sb_ac7_rows_for_vanished_transcripts_are_kept test_sb_merge_cost_beats_no_cost_against_existing_out \
  test_sb_merge_later_end_ts_wins_when_both_lack_cost test_sb_ac8_no_prompt_text_in_output \
  test_sb_never_modifies_transcripts test_sb_ac8a_dead_pid_lock_is_cleared_and_run_completes \
  test_sb_ac8a_live_pid_lock_makes_run_exit_0_untouched test_sb_ac8a_lock_older_than_6h_is_cleared_even_with_live_pid \
  test_sb_lock_removed_after_normal_run; do
  run_test "$t"
done
