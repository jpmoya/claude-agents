# #605 — goal_eval falls back to the go-granted tickets (real state) when the scope reads empty.
# Hand arithmetic: empty milestone scope + granted=[proj/repo-a#7]:
#   #7 closed completed -> total 1 delivered 1 | closed not_planned -> total 1 waiting 1 | open -> total 1 active 1
#   granted=[] -> total 0 (the #195 guard) | failed read of #7 -> exit 1 and an error event.
# Prefix gf_ / GF_. Placeholder repo names only.

HERE_GF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_GF=$(cd "$HERE_GF/../../.." && pwd)
SKILL_GF="$HERE_GF/.."

gf_setup() {  # gf_setup <issue json for #7 | ""> 
  GF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gf.XXXXXX")
  mkdir -p "$GF_DIR/bin" "$GF_DIR/pipe" "$GF_DIR/co-a"
  ( cd "$GF_DIR/co-a" && git init -q && git remote add origin https://github.com/proj/repo-a.git ) >/dev/null 2>&1
  [ -z "$1" ] || printf '%s' "$1" > "$GF_DIR/issue-7.json"
  echo '[]' > "$GF_DIR/comments.json"
  cat > "$GF_DIR/bin/gh" <<'EOF2'
#!/bin/bash
[ "$1" = "api" ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
shift; args=(); while [ $# -gt 0 ]; do case "$1" in --paginate) ;; *) args+=("$1") ;; esac; shift; done
case "${args[0]}" in
  repos/proj/repo-a/issues\?milestone=*) echo '[]' ;;
  repos/proj/repo-a/issues/7/comments*) cat "$D/comments.json" ;;
  repos/proj/repo-a/issues/7) [ -s "$D/issue-7.json" ] || { echo "HTTP 500" >&2; exit 1; }; cat "$D/issue-7.json" ;;
  *) echo "fake gh: unexpected ${args[0]}" >&2; exit 1 ;;
esac
EOF2
  chmod +x "$GF_DIR/bin/gh"
}
gf_teardown() { rm -rf "$GF_DIR"; }

# gf_run <granted json array> — goal_eval with an empty-milestone scope; prints "rc total delivered waiting active"
gf_run() {
  awk '/^[a-z_]+\(\) *\{.*\}[[:space:]]*(#.*)?$/ {print; next} /^[a-z_]+\(\) *\{/ {on=1} on {print} on && /^}/ {on=0}' "$SKILL_GF/supervisor.sh" > "$GF_DIR/sup-fns.sh"
  printf '{"spec":"proj/repo-a:milestone:12","issue":1,"granted":%s}' "$1" > "$GF_DIR/pipe/goal-proj_repo-a-ms-12.json"
  GF_OUT=$( export D="$GF_DIR" PATH="$GF_DIR/bin:$PATH" PIPE="$GF_DIR/pipe" LOGDIR="$GF_DIR/logs" HOST=host-test \
              SLOG="$GF_DIR/slog" GRACE_PERIOD_SECS=0 SLACK_WEBHOOK_URL=
            DISPATCH_REPOS=("proj/repo-a:$GF_DIR/co-a")
            . "$ROOT_GF/hooks/pipeline-markers.sh"; . "$SKILL_GF/pipeline-lib.sh"; . "$SKILL_GF/goal-lib.sh"
            SW_REGISTRY_LOADED=0; SW_REGISTRY_JSON=""
            . "$GF_DIR/sup-fns.sh"
            slog() { printf '%s\n' "$*" >> "$SLOG"; }
            report_status_async() { :; }
            pipeline_event() { printf '%s\n' "$*" >> "$D/events.log"; }
            goal_eval proj_repo-a-ms-12 proj/repo-a:milestone:12 2>"$GF_DIR/stderr"; rc=$?
            echo "$rc $GE_TOTAL $GE_DELIVERED $GE_WAITING $GE_ACTIVE" )
}

GF_OPEN='{"number":7,"state":"open","labels":[],"user":{"login":"jpmoya"},"body":"","milestone":{"state":"open","title":"v9"}}'

test_gf_granted_closed_completed_is_delivered() {
  gf_setup '{"number":7,"state":"closed","state_reason":"completed","labels":[],"user":{"login":"jpmoya"},"body":""}'
  local rc=0
  gf_run '["proj/repo-a#7"]'
  assert_eq "$GF_OUT" "0 1 1 0 0" "empty scope + shipped granted ticket -> delivered" || rc=1
  gf_teardown; return $rc
}

test_gf_granted_closed_not_planned_waits_on_jp() {
  gf_setup '{"number":7,"state":"closed","state_reason":"not_planned","labels":[],"user":{"login":"jpmoya"},"body":""}'
  local rc=0
  gf_run '["proj/repo-a#7"]'
  assert_eq "$GF_OUT" "0 1 0 1 0" "not_planned granted ticket -> waiting, never delivered (#557)" || rc=1
  gf_teardown; return $rc
}

test_gf_granted_open_moved_out_is_not_delivered() {
  gf_setup "$GF_OPEN"
  local rc=0
  gf_run '["proj/repo-a#7"]'
  assert_eq "$GF_OUT" "0 1 0 0 1" "open granted ticket -> active" || rc=1
  gf_teardown; return $rc
}

test_gf_empty_scope_empty_granted_unchanged() {
  gf_setup ""
  local rc=0
  gf_run '[]'
  assert_eq "$GF_OUT" "0 0 0 0 0" "#195 guard: nothing granted -> total 0" || rc=1
  gf_teardown; return $rc
}

test_gf_failed_granted_read_fails_closed_and_is_reported() {
  gf_setup ""
  local rc=0
  gf_run '["proj/repo-a#7"]'
  assert_eq "${GF_OUT%% *}" "1" "failed read -> goal_eval returns 1" \
    && assert_contains "$(cat "$GF_DIR/events.log" 2>/dev/null)" "cannot read granted ticket proj/repo-a#7" "error event captured" || rc=1
  gf_teardown; return $rc
}

test_gf_queue_derive_has_no_fake_open_rows() {
  local rc=0
  if grep -F '\topen"' "$SKILL_GF/goal-lib.sh" >/dev/null; then echo "goal_queue_derive still builds fake open rows"; rc=1; fi
  return $rc
}

run_test test_gf_granted_closed_completed_is_delivered
run_test test_gf_granted_closed_not_planned_waits_on_jp
run_test test_gf_granted_open_moved_out_is_not_delivered
run_test test_gf_empty_scope_empty_granted_unchanged
run_test test_gf_failed_granted_read_fails_closed_and_is_reported
run_test test_gf_queue_derive_has_no_fake_open_rows
