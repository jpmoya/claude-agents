# Issue #250 decision 1+2 (host half) — reconcile-status.sh classifies a held BLOCKED gate by the
# `Blocked on: <class>` line (line 2 of the BLOCKED comment). Non-JP-only classes get
# parked_reason=auto_retry and an empty .needs; needs_jp / missing / invalid class stays a JP gate.
# The payload carries the fixed class as runs[].block_class (test-chosen name) and never comment text.
# Own ar_ helpers (the nj_ ones load after this file). Placeholder repo names only. Bash 3.2 portable.

HERE_AR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AR="$HERE_AR/.."
AR_ALIAS="example-owner/project-a"
AR_GATE_T="2026-09-20T10:00:00Z"

ar_env() {
  AR_PIPE=$(new_pipe); AR_HOME=$(new_home)
  AR_REPO="$AR_PIPE/repo-project-a"
  fixture_repo "$AR_REPO" "$AR_ALIAS"
  AR_BIN="$AR_HOME/.local/bin"
  mk_fake_gh "$AR_BIN"
  echo "$AR_ALIAS" > "$AR_BIN/gh-name-with-owner"
  printf 'DISPATCH_REPOS=("%s:%s")\nSTATUS_REPO_ALIASES=("%s:project-a")\n' "$AR_ALIAS" "$AR_REPO" "$AR_ALIAS" \
    > "$AR_HOME/.claude/pipeline/config.local.sh"
}
ar_cleanup() { cleanup_running; rm -rf "$AR_PIPE" "$AR_HOME"; return 0; }
ar_file() { if [ -f "$1" ]; then head -n1 "$1"; else echo ABSENT; fi; }
# ar_gate <issue> <marker line> <line 2 or ""> — held ticket whose latest gate comment is that marker
ar_gate() {
  local n=$1 body=$2
  [ -z "${3-}" ] || body="$body"$'\n'"$3"
  mk_held "$AR_PIPE" "$n" "$AR_REPO"; printf 'Title of %s\n' "$n" > "$AR_PIPE/orch-$n.title"
  jq -nc --arg b "$body" --arg t "$AR_GATE_T" '[{body:$b, createdAt:$t, author:{login:"x"}}]' > "$AR_BIN/gh-issue-comments-json-$n"
}
ar_reconcile() {
  HOME="$AR_HOME" PATH="$AR_BIN:/usr/bin:/bin" PIPE="$AR_PIPE" QUEUE="$AR_PIPE/queue" LOGDIR="$AR_HOME/logs/pipeline" \
    "$RS_AR/reconcile-status.sh" --force >/dev/null 2>&1
}
ar_print() {
  HOME="$AR_HOME" PATH="$AR_BIN:/usr/bin:/bin" PIPE="$AR_PIPE" QUEUE="$AR_PIPE/queue" LOGDIR="$AR_HOME/logs/pipeline" \
    "$RS_AR/report-status.sh" --print 2>/dev/null
}
ar_field() {  # ar_field <json> <issue> <field>
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '[.runs[] | select((.issue|tostring)==$n)] | if length==0 then "NORUN" else (.[0] | if has($f) then (.[$f]|tostring) else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}
BLK='**[fullstack-developer] BLOCKED**'

test_ar_ci_red_is_auto_retry_with_empty_needs() {
  ar_env; ar_gate 501 "$BLK" 'Blocked on: ci_red — checks failing on the PR'
  ar_reconcile
  local r n; r=$(ar_file "$AR_PIPE/orch-501.parked_reason"); n=$(ar_file "$AR_PIPE/orch-501.needs")
  ar_cleanup
  assert_eq "$r" "auto_retry" "decision 2: Blocked on: ci_red -> parked_reason auto_retry" || return 1
  assert_eq "$n" "ABSENT" "decision 2: .needs is empty for a non-JP-only BLOCKED" || return 1
}

test_ar_every_non_jp_only_class_is_auto_retry() {
  local cls i=0 r
  for cls in ci_pending ci_red merge_conflict dependency unsupported_project other; do
    i=$((i + 1)); ar_env; ar_gate $((510 + i)) "$BLK" "Blocked on: $cls — some detail"
    ar_reconcile
    r=$(ar_file "$AR_PIPE/orch-$((510 + i)).parked_reason")
    ar_cleanup
    assert_eq "$r" "auto_retry" "decision 1: class $cls is NOT JP-only -> auto_retry" || return 1
  done
}

test_ar_needs_jp_class_stays_a_jp_gate() {
  ar_env; ar_gate 520 "$BLK" 'Blocked on: needs_jp — which vendor should we pick?'
  ar_reconcile
  local r n; r=$(ar_file "$AR_PIPE/orch-520.parked_reason"); n=$(ar_file "$AR_PIPE/orch-520.needs")
  ar_cleanup
  assert_eq "$r" "ABSENT" "decision 1: needs_jp -> no parked_reason" || return 1
  assert_eq "$n" "Decision needed" "decision 1: needs_jp keeps its Needs label" || return 1
}

test_ar_unparsable_or_missing_class_stays_a_jp_gate() {
  local i=0 line r n
  for line in 'Blocked on: which DB?' 'Blocked on: bogus_class — x' 'Blocked on:' 'blocked on: ci_red — lowercase prefix' ''; do
    i=$((i + 1)); ar_env; ar_gate $((530 + i)) "$BLK" "$line"
    ar_reconcile
    r=$(ar_file "$AR_PIPE/orch-$((530 + i)).parked_reason"); n=$(ar_file "$AR_PIPE/orch-$((530 + i)).needs")
    ar_cleanup
    assert_eq "$r" "ABSENT" "decision 1: line 2 [$line] -> conservative default, no parked_reason" || return 1
    assert_eq "$n" "Decision needed" "decision 1: line 2 [$line] -> still labelled Decision needed" || return 1
  done
}

test_ar_class_on_a_non_blocked_gate_is_ignored() {
  ar_env; ar_gate 540 '**[infra-operator] AWAITING GO**' 'Blocked on: ci_red — not a BLOCKED marker'
  ar_reconcile
  local r n; r=$(ar_file "$AR_PIPE/orch-540.parked_reason"); n=$(ar_file "$AR_PIPE/orch-540.needs")
  ar_cleanup
  assert_eq "$r" "ABSENT" "AWAITING GO is always JP-only" || return 1
  assert_eq "$n" "Say go" "AWAITING GO keeps Say go" || return 1
}

test_ar_stale_auto_retry_removed_when_class_becomes_needs_jp() {
  ar_env; ar_gate 550 "$BLK" 'Blocked on: ci_red — x'
  ar_reconcile
  local first; first=$(ar_file "$AR_PIPE/orch-550.parked_reason")
  ar_gate 550 "$BLK" 'Blocked on: needs_jp — now it needs JP'
  ar_reconcile
  local second; second=$(ar_file "$AR_PIPE/orch-550.parked_reason")
  ar_cleanup
  assert_eq "$first" "auto_retry" "control" || return 1
  assert_eq "$second" "ABSENT" "a later needs_jp BLOCKED clears auto_retry" || return 1
}

test_ar_payload_carries_fixed_labels_only() {
  ar_env; ar_gate 560 "$BLK" 'Blocked on: merge_conflict — hunter2-sekret in free text'
  ar_reconcile
  local out; out=$(ar_print)
  ar_cleanup
  assert_eq "$(ar_field "$out" 560 parked_reason)" "auto_retry" "runs[].parked_reason = auto_retry" || return 1
  assert_eq "$(ar_field "$out" 560 block_class)" "merge_conflict" "runs[].block_class = the fixed class" || return 1
  assert_eq "$(ar_field "$out" 560 needs)" "MISSING_FIELD" "runs[].needs omitted when empty" || return 1
  assert_not_contains "$out" "hunter2" "no comment text is published" || return 1
}

test_ar_payload_has_no_block_class_for_jp_gates() {
  ar_env; ar_gate 570 "$BLK" 'Blocked on: needs_jp — x'
  ar_reconcile
  local out; out=$(ar_print)
  ar_cleanup
  assert_eq "$(ar_field "$out" 570 parked_reason)" "MISSING_FIELD" "needs_jp: no parked_reason in payload" || return 1
}

run_test test_ar_ci_red_is_auto_retry_with_empty_needs
run_test test_ar_every_non_jp_only_class_is_auto_retry
run_test test_ar_needs_jp_class_stays_a_jp_gate
run_test test_ar_unparsable_or_missing_class_stays_a_jp_gate
run_test test_ar_class_on_a_non_blocked_gate_is_ignored
run_test test_ar_stale_auto_retry_removed_when_class_becomes_needs_jp
run_test test_ar_payload_carries_fixed_labels_only
run_test test_ar_payload_has_no_block_class_for_jp_gates
