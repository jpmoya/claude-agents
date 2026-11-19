# #780 AC5 (host half) — reconcile-status.sh publishes orch-<rk>.answered_at for a HELD ticket whose gate JP (or his delegate) has
# answered and that the supervisor has not relaunched yet (orch-<rk>.answered older than the answer); build-runs-json.py emits it as
# runs[].answered_at. Same detector as the supervisor (held_answer). Expected values are from the ticket. Placeholder names only.
HERE_AA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AA="$HERE_AA/.."
AA_ALIAS="example-owner/project-a"
AA_GATE_T="2026-09-20T10:00:00Z"
AA_ANS_T="2026-09-21T10:00:00Z"

aa_env() {
  AA_PIPE=$(new_pipe); AA_HOME=$(new_home); AA_REPO="$AA_PIPE/repo-project-a"
  fixture_repo "$AA_REPO" "$AA_ALIAS"; AA_BIN="$AA_HOME/.local/bin"
  mk_fake_gh "$AA_BIN"; echo "$AA_ALIAS" > "$AA_BIN/gh-name-with-owner"
  # the shared fake has no top-level issue author: add one (jp) to every `issue view` answer
  cp "$AA_BIN/gh" "$AA_BIN/gh-base"
  printf '#!/bin/bash\nHERE=$(cd "$(dirname "$0")" && pwd)\nout=$("$HERE/gh-base" "$@") || exit $?\ncase "$*" in *"issue view"*) printf "%%s" "$out" | jq -c ". + {author:{login:\\"jp\\"}}" ;; *) printf "%%s\\n" "$out" ;; esac\n' > "$AA_BIN/gh"; chmod +x "$AA_BIN/gh"
  printf 'DISPATCH_REPOS=("%s:%s")\nSTATUS_REPO_ALIASES=("%s:project-a")\n' "$AA_ALIAS" "$AA_REPO" "$AA_ALIAS" > "$AA_HOME/.claude/pipeline/config.local.sh"
}
aa_cleanup() { cleanup_running; rm -rf "$AA_PIPE" "$AA_HOME"; return 0; }
aa_c() {  # <id> <author> <body> <createdAt>
  jq -nc --argjson i "$1" --arg a "$2" --arg b "$3" --arg t "$4" '{url:("https://github.com/example-owner/project-a/issues/801#issuecomment-" + ($i|tostring)), body:$b, createdAt:$t, author:{login:$a}}'
}
aa_gate() { aa_c 100 bot $'**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp — pick one' "$AA_GATE_T"; }
aa_reconcile() {
  HOME="$AA_HOME" PATH="$AA_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$AA_PIPE" QUEUE="$AA_PIPE/queue" LOGDIR="$AA_HOME/logs/pipeline" \
    "$RS_AA/reconcile-status.sh" --force >/dev/null 2>&1
}
aa_print() {
  HOME="$AA_HOME" PATH="$AA_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$AA_PIPE" QUEUE="$AA_PIPE/queue" LOGDIR="$AA_HOME/logs/pipeline" \
    "$RS_AA/report-status.sh" --print 2>/dev/null
}
aa_file() { if [ -f "$1" ]; then head -n1 "$1"; else echo ABSENT; fi; }
aa_held() { mk_held "$AA_PIPE" 801 "$AA_REPO"; printf 'Title\n' > "$(rkp "$AA_PIPE/orch-801.title")"; }

test_aa_a_jp_go_after_the_gate_publishes_answered_at() {
  aa_env; aa_held
  printf '[%s,%s]' "$(aa_gate)" "$(aa_c 105 jp '**[jp] GO**' "$AA_ANS_T")" > "$AA_BIN/gh-issue-comments-json-801"
  aa_reconcile
  local at out; at=$(aa_file "$(rkp "$AA_PIPE/orch-801.answered_at")"); out=$(aa_print)
  local pub; pub=$(printf '%s' "$out" | jq -r '[.runs[] | select((.issue|tostring)=="801")][0].answered_at // "MISSING"')
  aa_cleanup
  assert_eq "$at" "$AA_ANS_T" "the answer's createdAt is stored" || return 1
  assert_eq "$pub" "$AA_ANS_T" "runs[].answered_at is published" || return 1
}
test_aa_no_answer_or_a_chatty_comment_publishes_nothing() {
  aa_env; aa_held
  printf '[%s,%s]' "$(aa_gate)" "$(aa_c 105 jp 'thanks, will look' "$AA_ANS_T")" > "$AA_BIN/gh-issue-comments-json-801"
  aa_reconcile
  local at out pub; at=$(aa_file "$(rkp "$AA_PIPE/orch-801.answered_at")"); out=$(aa_print)
  pub=$(printf '%s' "$out" | jq -r '[.runs[] | select((.issue|tostring)=="801")][0] | has("answered_at")')
  aa_cleanup
  assert_eq "$at" "ABSENT" "no strict answer, no answered_at" || return 1
  assert_eq "$pub" "false" "nothing published" || return 1
}
test_aa_an_answer_the_supervisor_already_relaunched_on_is_not_pending() {
  aa_env; aa_held
  printf '[%s,%s]' "$(aa_gate)" "$(aa_c 105 jp '**[jp] GO**' "$AA_ANS_T")" > "$AA_BIN/gh-issue-comments-json-801"
  printf '105\n' > "$(rkp "$AA_PIPE/orch-801.answered")"
  aa_reconcile
  local at; at=$(aa_file "$(rkp "$AA_PIPE/orch-801.answered_at")")
  aa_cleanup
  assert_eq "$at" "ABSENT" "loop-guard id 105 already acted on" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_aa_'); do run_test "$t"; done
