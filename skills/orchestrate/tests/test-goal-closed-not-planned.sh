# #619 — a closed "not planned" ticket counts as done when the newest pipeline closing comment says the pipeline decided it;
# otherwise (no marker, failed read) it stays waiting_jp (#557). Completed rows do no comments read.
# Hand arithmetic: one scope row "proj/repo-a#7 closed not_planned" -> total 1; delivered 1 waiting 0 | delivered 0 waiting 1.
# Prefix cn_ / CN_. Placeholder repo names only.

HERE_CN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_CN=$(cd "$HERE_CN/../../.." && pwd)
SKILL_CN="$HERE_CN/.."

cn_setup() {  # cn_setup <comments json | "FAIL">
  CN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-cn.XXXXXX")
  mkdir -p "$CN_DIR/bin" "$CN_DIR/pipe"
  if [ "$1" = FAIL ]; then : > "$CN_DIR/fail"; else printf '%s' "$1" > "$CN_DIR/comments.json"; fi
  cat > "$CN_DIR/bin/gh" <<'EOF2'
#!/bin/bash
[ "$1" = "api" ] || exit 1
shift; args=(); while [ $# -gt 0 ]; do case "$1" in --paginate) ;; *) args+=("$1") ;; esac; shift; done
case "${args[0]}" in
  repos/proj/repo-a/issues/7/comments*) echo x >> "$D/reads"; [ ! -e "$D/fail" ] || { echo "HTTP 500" >&2; exit 1; }; cat "$D/comments.json" ;;
  *) echo "fake gh: unexpected ${args[0]}" >&2; exit 1 ;;
esac
EOF2
  chmod +x "$CN_DIR/bin/gh"
}
cn_teardown() { rm -rf "$CN_DIR"; }

# cn_run <state_reason> — prints "rc total delivered waiting why"
cn_run() {
  local row; row=$(printf 'proj/repo-a#7\tclosed\t-\tjpmoya\t-\t%s\t-' "$1")
  CN_OUT=$( export D="$CN_DIR" PATH="$CN_DIR/bin:$PATH" PIPE="$CN_DIR/pipe" LOGDIR="$CN_DIR/logs" HOST=host-test SLOG="$CN_DIR/slog" SLACK_WEBHOOK_URL=
            DISPATCH_REPOS=("proj/repo-a:$CN_DIR")
            . "$ROOT_CN/hooks/pipeline-markers.sh"; . "$SKILL_CN/pipeline-lib.sh"; . "$SKILL_CN/goal-lib.sh"
            slog() { printf '%s\n' "$*" >> "$SLOG"; }
            report_status_async() { :; }
            pipeline_event() { printf '%s\n' "$*" >> "$D/events.log"; }
            goal_eval g proj/repo-a:milestone:1 "$row" 2>/dev/null; rc=$?
            echo "$rc $GE_TOTAL $GE_DELIVERED $GE_WAITING $(printf '%s' "$GE_REFS" | cut -f3 | head -1)" )
}

cn_case() {  # cn_case <comments json> <expected output>
  local rc=0
  cn_setup "$1"; cn_run not_planned
  assert_eq "$CN_OUT" "$2" "$3" || rc=1
  cn_teardown; return $rc
}
cn_c() { printf '[{"body":%s}]' "$(printf '%s' "$1" | jq -Rs .)"; }

test_cn_pm_rejected() { cn_case "$(cn_c $'**[product-manager] REJECTED**\nReason: duplicate of #5')" "0 1 1 0 closed, not planned — decided by product-manager" "PM REJECTED closes"; }
test_cn_dev_rejected() { cn_case "$(cn_c $'**[fullstack-developer] REJECTED**\nReason: cannot-reproduce')" "0 1 1 0 closed, not planned — decided by fullstack-developer" "developer REJECTED closes"; }
test_cn_intake_duplicate() { cn_case "$(cn_c '**[intake] DUPLICATE** of #5')" "0 1 1 0 closed, not planned — decided by intake" "intake DUPLICATE"; }
test_cn_intake_noise() { cn_case "$(cn_c '**[intake] NOISE**')" "0 1 1 0 closed, not planned — decided by intake" "intake NOISE"; }
test_cn_delivery_lead() { cn_case "$(cn_c $'**[delivery-lead] DECISION**\nResolves: x')" "0 1 1 0 closed, not planned — decided by delivery-lead" "delivery-lead DECISION"; }
test_cn_legacy_pm_decision() { cn_case "$(cn_c '**[project-manager] JP CONFIRMED**')" "0 1 1 0 closed, not planned — decided by project-manager" "legacy spelling"; }
test_cn_no_marker_waits() { cn_case "$(cn_c 'closed by hand')" "0 1 0 1 closed without shipping (not planned) — check it before the goal can finish" "no marker -> JP (#557)"; }
test_cn_rejected_without_reason_waits() { cn_case "$(cn_c $'**[product-manager] REJECTED**\nReason: needs-spec')" "0 1 0 1 closed without shipping (not planned) — check it before the goal can finish" "non-closing REJECTED -> JP"; }

test_cn_failed_read_fails_closed_and_reports() {
  local rc=0
  cn_setup FAIL; cn_run not_planned
  assert_eq "$CN_OUT" "0 1 0 1 closed without shipping (not planned) — check it before the goal can finish" "failed read -> waiting_jp" || rc=1
  grep -q "comments read failed" "$CN_DIR/slog" 2>/dev/null || { echo "goal_err not called"; rc=1; }
  cn_teardown; return $rc
}

test_cn_completed_does_no_read() {
  local rc=0
  cn_setup "$(cn_c '**[intake] NOISE**')"; cn_run completed
  assert_eq "$CN_OUT" "0 1 1 0 -" "completed -> delivered" || rc=1
  [ ! -e "$CN_DIR/reads" ] || { echo "unexpected comments read"; rc=1; }
  cn_teardown; return $rc
}
run_test test_cn_pm_rejected
run_test test_cn_dev_rejected
run_test test_cn_intake_duplicate
run_test test_cn_intake_noise
run_test test_cn_delivery_lead
run_test test_cn_legacy_pm_decision
run_test test_cn_no_marker_waits
run_test test_cn_rejected_without_reason_waits
run_test test_cn_failed_read_fails_closed_and_reports
run_test test_cn_completed_does_no_read
