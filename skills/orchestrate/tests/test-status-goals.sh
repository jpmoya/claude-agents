# Issue #197 (AC1, AC5) — the reporter publishes goals: build-runs-json.py `goals` mode, wired by
# report-status.sh as a top-level "goals" key only when non-empty. Reads $PIPE/goal-<id>.json
# (+ goal-<id>.pid / .held / .stopped) only; no network.
#
# Fixtures A-F from the ticket's "Test fixtures" section. Expected values hand-written from the
# ticket. Bash 3.2 portable; placeholder names only.

HERE_GL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_GL="$HERE_GL/.."

gl_env() { GL_PIPE=$(new_pipe); GL_HOME=$(new_home); }
gl_cleanup() { cleanup_running; rm -rf "$GL_PIPE" "$GL_HOME"; return 0; }

# gl_json <id> <json-object-text> — writes $PIPE/goal-<id>.json verbatim
gl_json() { printf '%s' "$2" > "$GL_PIPE/goal-$1.json"; }
# gl_goal <id> <state> [spec] [host] — a well-formed goal json
gl_goal() {
  jq -nc --arg id "$1" --arg st "$2" --arg spec "${3:-Spec of $1}" --arg host "${4:-mac}" \
    '{id:$id, spec:$spec, host:$host, state:$st, scope_total:7, scope_delivered:3, last_cycle_at:"2026-09-21T10:00:00Z", issue:193}' \
    > "$GL_PIPE/goal-$1.json"
}
gl_live_pid() { sleep 300 & RUNNING_PIDS="$RUNNING_PIDS $!"; echo "$!" > "$GL_PIPE/goal-$1.pid"; }
gl_dead_pid() { local p=99999; while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done; echo "$p" > "$GL_PIPE/goal-$1.pid"; }

gl_print() {
  HOME="$GL_HOME" PATH="$PATH" PIPE="$GL_PIPE" QUEUE="$GL_PIPE/queue" LOGDIR="$GL_HOME/logs/pipeline" \
    "$RS_GL/report-status.sh" --print 2>/dev/null
}
gl_mode() {  # direct call of the `goals` mode, no stdin
  PATH="$PATH" python3 "$RS_GL/build-runs-json.py" "" "$GL_HOME/.claude/pipeline/runs.jsonl" "$GL_PIPE" goals </dev/null 2>/dev/null
}

# The ticket's fixture: A running, B held, C waiting_jp, D corrupt, E hostile spec, F stopped.
gl_fixture() {
  gl_env
  gl_goal A active;  gl_live_pid A
  gl_goal B held;    touch "$GL_PIPE/goal-B.held"; gl_dead_pid B
  gl_goal C waiting_jp
  printf '{"id":"D","spec":"trunc' > "$GL_PIPE/goal-D.json"
  gl_goal E active '<script>alert(1)</script>'; gl_dead_pid E
  gl_goal F active;  touch "$GL_PIPE/goal-F.stopped"
}

test_gl_ac1_fixture_emits_exactly_four_entries() {
  gl_fixture
  local out; out=$(gl_print); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c '[.goals[].id] | sort')" '["A","B","C","E"]' "AC1: A,B,C,E emitted; D corrupt and F stopped skipped" || return 1
}

test_gl_ac1_states_and_fields() {
  gl_fixture
  local out; out=$(gl_print); gl_cleanup
  local g; g=$(printf '%s' "$out" | jq -c '.goals | map({(.id): .state}) | add')
  assert_eq "$g" '{"A":"running","B":"held","C":"waiting_jp","E":"between_cycles"}' "AC1: state mapping (live pid / .held / waiting_jp / no live pid)" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.goals[] | select(.id=="A")')" \
    '{"id":"A","spec":"Spec of A","host":"mac","state":"running","scope_total":7,"scope_delivered":3,"last_cycle_at":"2026-09-21T10:00:00Z"}' \
    "AC1: entry has exactly {id,spec,host,state,scope_total,scope_delivered,last_cycle_at}" || return 1
}

test_gl_ac1_reporter_does_not_sanitise_spec() {
  gl_fixture
  local out; out=$(gl_print); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.goals[] | select(.id=="E") | .spec')" '<script>alert(1)</script>' "AC1: E's raw spec is passed through" || return 1
}

test_gl_ac1_empty_pipe_has_no_goals_key() {
  gl_env
  local out; out=$(gl_print); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c 'has("goals")')" "false" "AC1: no goals -> no goals key" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c 'keys')" '["approved","capacity","completed","runs","sent_at","staging","supervisor_last_tick","v"]' "AC1: payload keys exactly as before" || return 1
}

test_gl_only_skipped_goals_has_no_goals_key() {
  gl_env
  printf 'not json' > "$GL_PIPE/goal-D.json"
  gl_goal F active; touch "$GL_PIPE/goal-F.stopped"
  local out; out=$(gl_print); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c 'has("goals")')" "false" "only corrupt/stopped goals -> key omitted, not []" || return 1
}

test_gl_held_file_wins_over_active_json_state() {
  gl_env
  gl_goal H active; touch "$GL_PIPE/goal-H.held"; gl_live_pid H
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "held" ".held file -> held even if json says active and pid is live" || return 1
}

test_gl_active_with_dead_pid_is_between_cycles() {
  gl_env
  gl_goal G active; gl_dead_pid G
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "between_cycles" "active + dead pid -> between_cycles" || return 1
}

test_gl_active_with_no_pid_file_is_between_cycles() {
  gl_env
  gl_goal G active
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "between_cycles" "active + no .pid -> between_cycles" || return 1
}

test_gl_unknown_state_is_skipped() {
  gl_env
  gl_goal X exploded; gl_goal OK waiting_jp
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].id]')" '["OK"]' "unknown json state -> entry skipped" || return 1
}

test_gl_missing_required_field_is_skipped() {
  gl_env
  gl_json NOHOST '{"id":"NOHOST","spec":"s","state":"held"}'
  gl_json NOSPEC '{"id":"NOSPEC","host":"mac","state":"held"}'
  gl_json NOID '{"spec":"s","host":"mac","state":"held"}'
  gl_json NUMID '{"id":5,"spec":"s","host":"mac","state":"held"}'
  gl_goal OK held
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].id]')" '["OK"]' "missing/non-string id|spec|host -> skipped silently" || return 1
}

test_gl_missing_mirror_fields_default() {
  gl_env
  gl_json M '{"id":"M","spec":"s","host":"vm"}'            # no state, no counts, no last_cycle_at
  gl_json N '{"id":"N","spec":"s","host":"vm"}'; touch "$GL_PIPE/goal-N.held"
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c 'map({id,state}) | sort_by(.id)')" '[{"id":"M","state":"between_cycles"},{"id":"N","state":"held"}]' "no json state: .held -> held, else active (-> between_cycles with no live pid)" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.[] | select(.id=="M") | keys')" '["host","id","spec","state"]' "missing counts / last_cycle_at are omitted" || return 1
}

test_gl_caps_at_50_entries() {
  gl_env
  local i
  for i in $(seq 1 51); do gl_goal "g$i" held; done
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq 'length')" "50" "max 50 entries" || return 1
}

test_gl_exactly_50_entries_all_kept() {
  gl_env
  local i
  for i in $(seq 1 50); do gl_goal "g$i" held; done
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq 'length')" "50" "50 goals -> 50 entries (boundary)" || return 1
}

test_gl_wiring_leaves_runs_untouched() {
  gl_env
  gl_goal A held
  local out; out=$(gl_print); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c '.runs')" "[]" "goals do not leak into runs[]" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.goals | length')" "1" "goals key present when non-empty" || return 1
}

test_gl_ac5_scripts_bash_n_clean() {
  local f
  for f in report-status.sh; do
    bash -n "$RS_GL/$f" || { fail "AC5: bash -n failed for $f"; return 1; }
  done
}

test_gl_ac5_builder_is_stdlib_only() {
  # Every import in build-runs-json.py is a stdlib module (hand-listed allowlist).
  local bad
  bad=$(grep -E '^\s*(import|from) ' "$RS_GL/build-runs-json.py" | sed -E 's/^\s*(import|from) +([a-zA-Z0-9_]+).*/\2/' \
    | grep -vxE 'sys|json|subprocess|os|re|datetime|time|glob|signal|errno|pathlib|collections' || true)
  assert_eq "$bad" "" "AC5: only stdlib imports in build-runs-json.py" || return 1
}

run_test test_gl_ac1_fixture_emits_exactly_four_entries
run_test test_gl_ac1_states_and_fields
run_test test_gl_ac1_reporter_does_not_sanitise_spec
run_test test_gl_ac1_empty_pipe_has_no_goals_key
run_test test_gl_only_skipped_goals_has_no_goals_key
run_test test_gl_held_file_wins_over_active_json_state
run_test test_gl_active_with_dead_pid_is_between_cycles
run_test test_gl_active_with_no_pid_file_is_between_cycles
run_test test_gl_unknown_state_is_skipped
run_test test_gl_missing_required_field_is_skipped
run_test test_gl_missing_mirror_fields_default
run_test test_gl_caps_at_50_entries
run_test test_gl_exactly_50_entries_all_kept
run_test test_gl_wiring_leaves_runs_untouched
run_test test_gl_ac5_scripts_bash_n_clean
run_test test_gl_ac5_builder_is_stdlib_only
