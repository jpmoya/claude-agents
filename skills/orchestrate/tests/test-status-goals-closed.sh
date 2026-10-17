# Status page Goals section — closed goals. The supervisor's goal_queue_save adds `recent` (the registry's recently
# closed goals, newest first, max 5) to goalqueue.json; build-runs-json.py `goals` mode reports them as state
# delivered / stopped with closed_at. Expected values hand-written. Prefix gc_.

GC_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_GC="$GC_HERE/.."

gc_goals() { PATH="$PATH" python3 "$RS_GC/build-runs-json.py" "" "$GC_PIPE/runs.jsonl" "$GC_PIPE" goals </dev/null 2>/dev/null; }

test_gc_reporter_emits_recent_closed_goals() {
  GC_PIPE=$(new_pipe)
  cat > "$GC_PIPE/goalqueue.json" <<'J'
{"at":1,"candidate":null,"queued":[],"recent":[
 {"id":"d1","issue":60,"spec":"","title":"Delivered one","repos":["example-owner/project-a"],"st":"delivered","closed_at":"2026-09-20T09:00:00Z"},
 {"id":"s1","issue":61,"spec":"Old spec goal","title":"","repos":[],"st":"stopped","closed_at":"2026-09-19T09:00:00Z"},
 {"id":"x1","issue":62,"title":"Bad state","st":"active","closed_at":"2026-09-18T09:00:00Z"}]}
J
  local j; j=$(gc_goals); rm -rf "$GC_PIPE"
  assert_eq "$(printf '%s' "$j" | jq -c 'map({id,state,host,closed_at,title:(.title//null),spec:(.spec//null)})')" \
    '[{"id":"d1","state":"delivered","host":"","closed_at":"2026-09-20T09:00:00Z","title":"Delivered one","spec":null},{"id":"s1","state":"stopped","host":"","closed_at":"2026-09-19T09:00:00Z","title":null,"spec":"Old spec goal"}]' \
    "closed goals reported with outcome and date; a non-closed state in recent is skipped" || return 1
}

test_gc_reporter_skips_recent_goal_that_is_cached_or_queued() {
  GC_PIPE=$(new_pipe)
  printf '%s' '{"id":"d1","spec":"s","host":"mac","state":"active"}' > "$GC_PIPE/goal-d1.json"
  echo '{"at":1,"queued":[],"recent":[{"id":"d1","spec":"s","st":"delivered","closed_at":"2026-09-20T09:00:00Z"}]}' > "$GC_PIPE/goalqueue.json"
  local j; j=$(gc_goals); rm -rf "$GC_PIPE"
  assert_eq "$(printf '%s' "$j" | jq -c 'map(.state)')" '["between_cycles"]' "a goal with a live cache is not also listed as closed" || return 1
}

test_gc_reporter_caps_recent_at_five() {
  GC_PIPE=$(new_pipe)
  jq -nc '{at:1,queued:[],recent:[range(1;9)|{id:"g\(.)",spec:"s\(.)",st:"delivered",closed_at:"2026-09-20T09:00:00Z"}]}' > "$GC_PIPE/goalqueue.json"
  local j; j=$(gc_goals); rm -rf "$GC_PIPE"
  assert_eq "$(printf '%s' "$j" | jq -c 'map(.id)')" '["g1","g2","g3","g4","g5"]' "only the 5 most recent closed goals are reported" || return 1
}

test_gc_queue_save_writes_recent_newest_first() {
  GC_PIPE=$(new_pipe)
  local reg out
  reg='[{"issue":60,"id":"old","spec":"","host":"","state":"closed","closed_at":"2026-09-10T09:00:00Z","st":"delivered","block":{"title":"Old","repos":["example-owner/project-a"]}},
        {"issue":61,"id":"new","spec":"","host":"","state":"closed","closed_at":"2026-09-20T09:00:00Z","st":"stopped","block":{"title":"New"}},
        {"issue":62,"id":"live","spec":"s","host":"mac","state":"open","closed_at":null,"st":"active","block":{}}]'
  out=$(PIPE="$GC_PIPE" bash -c ". '$RS_GC/config.sh' >/dev/null 2>&1; PIPE='$GC_PIPE'; . '$RS_GC/pipeline-lib.sh' >/dev/null 2>&1; . '$RS_GC/goal-lib.sh' >/dev/null 2>&1; PIPE='$GC_PIPE'; goal_queue_save \"\$1\"; jq -c '.recent|map({id,st,closed_at,title})' '$GC_PIPE/goalqueue.json'" _ "$reg")
  rm -rf "$GC_PIPE"
  assert_eq "$out" '[{"id":"new","st":"stopped","closed_at":"2026-09-20T09:00:00Z","title":"New"},{"id":"old","st":"delivered","closed_at":"2026-09-10T09:00:00Z","title":"Old"}]' \
    "goalqueue.json recent: closed goals only, newest first" || return 1
}

echo "-- status goals: closed"
run_test test_gc_reporter_emits_recent_closed_goals
run_test test_gc_reporter_skips_recent_goal_that_is_cached_or_queued
run_test test_gc_reporter_caps_recent_at_five
run_test test_gc_queue_save_writes_recent_newest_first
