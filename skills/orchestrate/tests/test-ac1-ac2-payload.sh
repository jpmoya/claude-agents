# AC1 — given a fixture pipeline-state directory with two running orchestrators, one queued, and
#        one held run, the shared state-derivation function used by both `orchestrate.sh status`
#        and the reporter returns all four with correct `state`, `stage`, `issue`, and repo alias.
# AC2 — a run that is `held` in one reporter invocation and `stopped` (or removed/done) in the
#        next, against the same fixture directory advanced between calls, omits that run entirely
#        from the second payload — no done/stopped state is ever emitted.
#
# Exercised through `report-status.sh --print` (build + print the v1 payload; no lock, no network,
# no state write — the design says ACs 1/2/5 test against exactly this entry point).

HERE_AC12P=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC12P="$HERE_AC12P/.."

print_payload() {  # print_payload <pipe> <home>
  ( PIPE="$1" QUEUE="$1/queue" HOME="$2" "$RS_AC12P/report-status.sh" --print )
}

# run_field <json> <issue> <field> — pulls runs[] entry for <issue>'s <field>, or "MISSING" if
# that issue isn't present in the payload at all (distinguishing "wrong value" from "omitted").
run_field() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print('INVALID_JSON'); sys.exit()
for r in d.get('runs', []):
    if str(r.get('issue')) == str(sys.argv[2]):
        print(r.get(sys.argv[3], 'MISSING_FIELD')); sys.exit()
print('MISSING')
" "$1" "$2" "$3" 2>/dev/null
}

test_ac1_payload_has_all_four_runs_correct_fields() {
  local pipe home repoA repoB out
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  repoB="$pipe/repo-other"; fixture_repo "$repoB" "example-owner/totally-unmapped-repo"

  mk_running "$pipe" 201 "$repoA"
  mk_stage_log "$pipe" 201 "test-writer" 5
  mk_stage_log "$pipe" 201 "fullstack-developer" 1   # newest -> stage should read fullstack-developer

  mk_running "$pipe" 202 "$repoB"
  mk_stage_log "$pipe" 202 "code-reviewer" 0

  mk_queued "$pipe" 203 "$repoA"

  mk_held "$pipe" 204 "$repoB"

  out=$(print_payload "$pipe" "$home")
  cleanup_running; rm -rf "$pipe" "$home"

  assert_eq "$(run_field "$out" 201 state)" "running" "AC1: #201 state" || return 1
  assert_eq "$(run_field "$out" 201 stage)" "fullstack-developer" "AC1: #201 stage = newest-mtime log" || return 1
  assert_eq "$(run_field "$out" 202 state)" "running" "AC1: #202 state" || return 1
  assert_eq "$(run_field "$out" 203 state)" "queued" "AC1: #203 (queued) state" || return 1
  assert_eq "$(run_field "$out" 204 state)" "held" "AC1: #204 (held) state" || return 1
  local n
  n=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('runs',[])))" "$out" 2>/dev/null)
  assert_eq "$n" "4" "AC1: payload.runs has exactly the 4 fixture runs" || return 1
}

test_ac1_repo_alias_mapped_and_unmapped() {
  local pipe home repoA repoOther out
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  repoOther="$pipe/repo-unmapped"; fixture_repo "$repoOther" "example-owner/some-unlisted-repo"
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_REPO_ALIASES=("example-owner/project-a:project-a")
EOF

  mk_running "$pipe" 205 "$repoA"
  mk_running "$pipe" 206 "$repoOther"

  out=$(print_payload "$pipe" "$home")
  cleanup_running; rm -rf "$pipe" "$home"

  assert_eq "$(run_field "$out" 205 repo)" "project-a" "AC1/AC5: mapped repo published as its alias" || return 1
  assert_eq "$(run_field "$out" 206 repo)" "other" "AC5: repo absent from the alias map is published as \"other\"" || return 1
}

test_ac2_held_then_stopped_omitted_from_next_payload() {
  local pipe home repoA out1 out2
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"

  mk_held "$pipe" 207 "$repoA"
  out1=$(print_payload "$pipe" "$home")
  assert_eq "$(run_field "$out1" 207 state)" "held" "AC2: first payload carries #207 as held" || { rm -rf "$pipe" "$home"; return 1; }

  # advance the SAME fixture directory: held -> stopped (a manual `orchestrate.sh stop`)
  rm -f "$pipe/orch-207.held"
  touch "$pipe/orch-207.stopped"

  out2=$(print_payload "$pipe" "$home")
  rm -rf "$pipe" "$home"

  assert_eq "$(run_field "$out2" 207 state)" "MISSING" "AC2: #207 omitted entirely once stopped (never emitted as stopped/done)" || return 1
}

test_ac2_done_omitted_from_payload() {
  local pipe home repoA out
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  mk_done "$pipe" 208 "$repoA"
  out=$(print_payload "$pipe" "$home")
  rm -rf "$pipe" "$home"
  assert_eq "$(run_field "$out" 208 state)" "MISSING" "AC2: a done run is omitted entirely, never emitted as \"done\"" || return 1
}

run_test test_ac1_payload_has_all_four_runs_correct_fields
run_test test_ac1_repo_alias_mapped_and_unmapped
run_test test_ac2_held_then_stopped_omitted_from_next_payload
run_test test_ac2_done_omitted_from_payload
