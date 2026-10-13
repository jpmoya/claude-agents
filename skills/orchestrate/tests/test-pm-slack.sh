# Issue #117 — project manager <-> JP Slack DM (skills/orchestrate/pm-slack.sh: `ask` / `poll`).
#
# Black-box: the script runs in an isolated HOME/PIPE with three fakes first on PATH (config.sh
# prepends $HOME/.local/bin, so that is where they live): `curl` (canned JSON per Slack method,
# every call logged one line per call to $PMS_DATA/calls.log as "<method> <args+body>"), the shared
# fake `gh` (logs to gh-calls.log), and `date` (`+%s` answers $FAKE_NOW — the fake clock; anything
# else is real date). Stub-curl knobs: $PMS_DATA/resp-<method> (canned response), fail-<method>
# (curl exits 7), slow-<method> (sleeps). conversations.history honours `oldest` (exclusive) like
# Slack does, so "re-reads nothing" is observable.
# Interface assumptions the tests need (recorded in the handoff): the Slack text must reach curl
# unencoded in its args/body (--data-urlencode "text=..." or a JSON body), the repo arg is
# owner/repo (short name = part after "/"), ids/ts in fixtures are placeholders.

HERE_PMS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_PMS="$HERE_PMS/.."
ROOT_PMS=$(cd "$HERE_PMS/../../.." && pwd)

PMS_JP=UJPTEST1
PMS_BOT=UBOTTEST1
PMS_T0=1700000000          # fake "now" for the first call in a test
PMS_REPO_A="example-owner/project-a"
PMS_REPO_B="example-owner/project-b"
PMS_REPLY_TAIL_RE='Reply here with #%s and your answer\.'

pms_setup() {
  PMS_PIPE=$(new_pipe); PMS_HOME=$(new_home); PMS_DATA=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-pms.XXXXXX")
  PMS_BIN="$PMS_HOME/.local/bin"
  mkdir -p "$PMS_BIN"
  mk_fake_gh "$PMS_BIN"
  : > "$PMS_DATA/calls.log"
  cat > "$PMS_BIN/curl" <<'CURL_EOF'
#!/bin/bash
D=${PMS_DATA:?}
method=""; body=""
for a in "$@"; do
  case "$a" in *slack.com/api/*) m=${a##*slack.com/api/}; method=${m%%\?*} ;; esac
  case "$a" in *@*) f=${a#*@}; [ -f "$f" ] && body="$body $(cat "$f")" ;; esac
done
stdin=""; [ -t 0 ] || stdin=$(cat)
flat=$(printf '%s %s %s' "$*" "$body" "$stdin" | tr '\n' ' ')
[ -n "$method" ] || { echo "fake curl: no slack method in: $*" >&2; exit 2; }
printf '%s %s\n' "$method" "$flat" >> "$D/calls.log"
[ -f "$D/fail-$method" ] && exit 7
[ -f "$D/slow-$method" ] && sleep 0.4
if [ -f "$D/resp-$method" ]; then resp=$(cat "$D/resp-$method")
else
  case "$method" in
    conversations.open) resp='{"ok":true,"channel":{"id":"DTEST1"}}' ;;
    chat.postMessage) resp=$(printf '{"ok":true,"channel":"DTEST1","ts":"1700000000.%06d"}' "$(wc -l < "$D/calls.log")") ;;
    conversations.history) resp='{"ok":true,"messages":[]}' ;;
    *) resp='{"ok":true}' ;;
  esac
fi
if [ "$method" = conversations.history ]; then
  oldest=$(printf '%s' "$flat" | sed -n 's/.*oldest[^0-9]*\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$oldest" ]; then
    resp=$(printf '%s' "$resp" | jq -c --arg o "$oldest" 'if .ok then .messages |= map(select((.ts|tonumber) > ($o|tonumber))) else . end')
  fi
fi
printf '%s' "$resp"
CURL_EOF
  cat > "$PMS_BIN/date" <<'DATE_EOF'
#!/bin/bash
if [ -n "${FAKE_NOW:-}" ]; then
  for a in "$@"; do [ "$a" = "+%s" ] && { echo "$FAKE_NOW"; exit 0; }; done
fi
exec /bin/date "$@"
DATE_EOF
  chmod +x "$PMS_BIN/curl" "$PMS_BIN/date"
  PMS_NOW=$PMS_T0
  unset PMS_RC
}

# pms_run <subcommand> [args...] — runs pm-slack.sh; sets PMS_RC, PMS_OUT (stdout+stderr).
pms_run() {
  PMS_OUT=$( cd "$PMS_HOME" && env -u PM_SLACK_BOT_TOKEN -u SLACK_BOT_TOKEN -u PM_SLACK_USER_ID \
      PIPE="$PMS_PIPE" QUEUE="$PMS_PIPE/queue" LOGDIR="$PMS_HOME/logs/pipeline" HOME="$PMS_HOME" PMS_DATA="$PMS_DATA" \
      FAKE_NOW="$PMS_NOW" PM_SLACK_BOT_TOKEN="${PMS_TOKEN-fake-not-a-real-token}" PM_SLACK_USER_ID="${PMS_USER-$PMS_JP}" \
      "$RS_PMS/pm-slack.sh" "$@" 2>&1 </dev/null )
  PMS_RC=$?
}

pms_n()    { local c; c=$(grep -c "^$1 " "$PMS_DATA/calls.log" 2>/dev/null); echo "${c:-0}"; }   # calls of a Slack method
pms_lines() { grep "^$1 " "$PMS_DATA/calls.log" 2>/dev/null; }
pms_gh_n() { gh_call_count "$PMS_BIN" "$1"; }

# pms_history <ts|user|text>... — canned conversations.history (given order = newest first, like Slack).
pms_history() {
  local j='[]' m ts rest u t
  for m in "$@"; do
    ts=${m%%|*}; rest=${m#*|}; u=${rest%%|*}; t=${rest#*|}
    j=$(printf '%s' "$j" | jq -c --arg ts "$ts" --arg u "$u" --arg t "$t" '. + [{type:"message",user:$u,text:$t,ts:$ts}]')
  done
  printf '{"ok":true,"messages":%s,"has_more":false}' "$j" > "$PMS_DATA/resp-conversations.history"
}

pms_ask() { pms_run ask "$1" "$2" "${3:-Blocked item. Options: A or B. Recommend A.}"; }

# ---------------------------------------------------------------- AC1
test_pms_ask_posts_one_top_level_message_and_comments_once() {
  pms_setup
  echo '{"ok":true,"channel":"DTEST1","ts":"1700000001.000100"}' > "$PMS_DATA/resp-chat.postMessage"
  pms_ask "$PMS_REPO_A" 42 "Blocked: pick A or B. Recommend A."
  assert_exit0 "$PMS_RC" "AC1: ask exits 0 ($PMS_OUT)" || return 1
  assert_eq "$(pms_n conversations.open)" 1 "AC1: one conversations.open" || return 1
  assert_contains "$(pms_lines conversations.open)" "$PMS_JP" "AC1: DM opened with the JP user id" || return 1
  assert_eq "$(pms_n chat.postMessage)" 1 "AC1: exactly one chat.postMessage" || return 1
  local line; line=$(pms_lines chat.postMessage)
  assert_not_contains "$line" "thread_ts" "AC1: top-level, never a thread" || return 1
  assert_contains "$line" "DTEST1" "AC1: posted into the opened DM channel" || return 1
  printf '%s' "$line" | grep -Eq 'text["=: ]*#42 · project-a' || { fail "AC1: text must start '#42 · project-a': $line"; return 1; }
  printf '%s' "$line" | grep -Eq '#42 · project-a.*Blocked: pick A or B\. Recommend A\..*Reply here with #42 and your answer\.' \
    || { fail "AC1: header, then caller text, then the reply instruction: $line"; return 1; }
  printf '%s' "$line" | grep -Eq 'Reply here with #42 and your answer\.("|'"'"'|}|$| )' || { fail "AC1: text must END with the reply instruction: $line"; return 1; }
  assert_eq "$(pms_gh_n 'issue comment')" 1 "AC1: gh issue comment called once" || return 1
  local c; c=$(gh_calls "$PMS_BIN" | grep 'issue comment')
  assert_contains "$c" "issue comment 42" "AC1: comment goes on issue 42" || return 1
  assert_contains "$c" "$PMS_REPO_A" "AC1: comment goes to the ask's repo" || return 1
  assert_contains "$c" "**[project-manager] NOTE** slack-ask: 1700000001.000100" "AC1: slack-ask note carries the message ts" || return 1
}

test_pms_ask_defaults_to_jp_user_id() {
  pms_setup
  PMS_USER=""; pms_ask "$PMS_REPO_A" 42; unset PMS_USER
  # PM_SLACK_USER_ID set-but-empty must fall back too (${VAR:-default}).
  assert_contains "$(pms_lines conversations.open)" "U0A8FPA9V0E" "AC1: default JP id when PM_SLACK_USER_ID is unset/empty" || return 1
}

test_pms_ask_slack_errors_exit_nonzero_and_record_nothing() {
  local case_ resp
  for case_ in open-ok-false post-ok-false open-curl-fail post-curl-fail; do
    pms_setup
    case "$case_" in
      open-ok-false)  echo '{"ok":false,"error":"channel_not_found"}' > "$PMS_DATA/resp-conversations.open" ;;
      post-ok-false)  echo '{"ok":false,"error":"not_in_channel"}' > "$PMS_DATA/resp-chat.postMessage" ;;
      open-curl-fail) : > "$PMS_DATA/fail-conversations.open" ;;
      post-curl-fail) : > "$PMS_DATA/fail-chat.postMessage" ;;
    esac
    pms_ask "$PMS_REPO_A" 42
    assert_ne "$PMS_RC" 0 "AC1/spec [$case_]: ask exits non-zero on a Slack/curl error" || return 1
    [ -n "$PMS_OUT" ] || { fail "[$case_]: ask must print an error message"; return 1; }
    assert_eq "$(pms_gh_n 'issue comment')" 0 "[$case_]: no slack-ask comment when nothing was posted" || return 1
    # nothing recorded as open: after Slack recovers, the same ask goes through
    rm -f "$PMS_DATA"/resp-* "$PMS_DATA"/fail-*
    local before; before=$(pms_n chat.postMessage)
    pms_ask "$PMS_REPO_A" 42
    assert_exit0 "$PMS_RC" "[$case_]: retry ask ($PMS_OUT)" || return 1
    assert_eq "$(( $(pms_n chat.postMessage) - before ))" 1 "[$case_]: failed ask left no open ask behind — retry posts" || return 1
  done
}

# ---------------------------------------------------------------- AC2
test_pms_second_ask_while_open_is_a_noop() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42; assert_exit0 "$PMS_RC" "first ask" || return 1
  assert_eq "$(pms_n chat.postMessage)" 1 "AC2: first ask posted" || return 1
  PMS_NOW=$((PMS_T0 + 3600)); pms_ask "$PMS_REPO_A" 42
  assert_exit0 "$PMS_RC" "AC2: no-op ask still exits 0" || return 1
  assert_eq "$(pms_n chat.postMessage)" 1 "AC2: zero new chat.postMessage while the ask is open" || return 1
  assert_eq "$(pms_gh_n 'issue comment')" 1 "AC2: no new slack-ask comment either" || return 1
}

test_pms_ask_for_another_issue_is_independent() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42; pms_ask "$PMS_REPO_B" 43
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: one open ask per issue — a different issue still posts" || return 1
}

test_pms_one_reminder_after_24h_then_never() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  PMS_NOW=$((PMS_T0 + 86400 - 60)); pms_ask "$PMS_REPO_A" 42   # 23h59 — boundary, too early
  assert_eq "$(pms_n chat.postMessage)" 1 "AC2: no reminder just before 24h" || return 1
  PMS_NOW=$((PMS_T0 + 86400 + 60)); pms_ask "$PMS_REPO_A" 42   # 24h01 — the one reminder
  assert_exit0 "$PMS_RC" "AC2: reminder ask exits 0 ($PMS_OUT)" || return 1
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: exactly one reminder after 24h" || return 1
  assert_not_contains "$(pms_lines chat.postMessage | tail -n 1)" "thread_ts" "AC2: reminder is top-level" || return 1
  PMS_NOW=$((PMS_T0 + 86400 * 3)); pms_ask "$PMS_REPO_A" 42    # any later time: never again
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: no second reminder for the same ask" || return 1
  PMS_NOW=$((PMS_T0 + 86400 * 30)); pms_ask "$PMS_REPO_A" 42
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: still none a month later" || return 1
}

test_pms_reminder_clock_starts_at_the_ask_not_at_the_last_call() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  PMS_NOW=$((PMS_T0 + 20 * 3600)); pms_ask "$PMS_REPO_A" 42   # no-op at 20h must not reset the clock
  PMS_NOW=$((PMS_T0 + 25 * 3600)); pms_ask "$PMS_REPO_A" 42   # 25h after the ask, 5h after the no-op
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: 24h is measured from the ask (reminder due at 25h)" || return 1
}

test_pms_new_ask_allowed_after_jp_answered() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000100.000100|$PMS_JP|#42 go with A"
  PMS_NOW=$((PMS_T0 + 600)); pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  PMS_NOW=$((PMS_T0 + 900)); pms_ask "$PMS_REPO_A" 42 "Second question."
  assert_eq "$(pms_n chat.postMessage)" 2 "AC2: after JP answered, a new ask posts" || return 1
  assert_eq "$(pms_gh_n 'slack-ask')" 2 "AC2: and records its own slack-ask note" || return 1
}

# ---------------------------------------------------------------- AC3
test_pms_poll_ignores_bot_and_other_users() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000103.000100|U0OTHER99|#42 answer from someone else" \
              "1700000102.000100|$PMS_BOT|#42 the bot's own words" \
              "1700000101.000100|$PMS_BOT|Reply here with #42 and your answer."
  pms_run poll
  assert_exit0 "$PMS_RC" "poll exits 0 ($PMS_OUT)" || return 1
  assert_eq "$(pms_n conversations.history)" 1 "AC3: poll did read the history (non-vacuous)" || return 1
  assert_eq "$(pms_gh_n 'jp-reply')" 0 "AC3: no jp-reply comment for non-JP messages" || return 1
  assert_eq "$(pms_gh_n 'issue comment')" 1 "AC3: only the original slack-ask comment exists" || return 1
  assert_eq "$(pms_n reactions.add)" 0 "AC3: no reaction on non-JP messages" || return 1
  assert_eq "$(pms_n chat.postMessage)" 1 "AC3: no clarifying reply to non-JP messages either" || return 1
}

test_pms_poll_only_accepts_the_configured_user_id() {
  pms_setup
  PMS_USER=UOTHERJP2
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000102.000100|UOTHERJP2|#42 real answer" "1700000101.000100|$PMS_JP|#42 default-id user, but PM_SLACK_USER_ID says otherwise"
  pms_run poll; unset PMS_USER
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC3: only the PM_SLACK_USER_ID message is accepted" || return 1
  assert_contains "$(gh_calls "$PMS_BIN" | grep 'jp-reply')" "#42 real answer" "AC3: PM_SLACK_USER_ID (not a hard-coded id) decides who is JP" || return 1
}

# ---------------------------------------------------------------- AC4
test_pms_poll_matches_token_to_the_right_ask_among_several() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42; pms_ask "$PMS_REPO_B" 43
  pms_history "1700000101.000100|$PMS_JP|#43 use option B"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  local c; c=$(gh_calls "$PMS_BIN" | grep 'jp-reply')
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC4: exactly one jp-reply comment" || return 1
  assert_contains "$c" "issue comment 43" "AC4: on issue 43" || return 1
  assert_contains "$c" "$PMS_REPO_B" "AC4: in issue 43's repo" || return 1
  assert_not_contains "$c" "issue comment 42" "AC4: not on issue 42" || return 1
  assert_eq "$(pms_n chat.postMessage)" 2 "AC4: a matched reply needs no clarifying message" || return 1
  # 42 is still pending: a token-less message now falls back to it (the sole pending ask)
  pms_history "1700000102.000100|$PMS_JP|thanks, and for the other one: A"  "1700000101.000100|$PMS_JP|#43 use option B"
  pms_run poll
  assert_contains "$(gh_calls "$PMS_BIN" | grep 'jp-reply' | tail -n 1)" "issue comment 42" "AC4: 42 stayed pending after 43 was answered" || return 1
}

test_pms_poll_token_boundary_42_is_not_4() {
  pms_setup
  pms_ask "$PMS_REPO_A" 4; pms_ask "$PMS_REPO_A" 42
  pms_history "1700000101.000100|$PMS_JP|#42 yes"
  pms_run poll
  local c; c=$(gh_calls "$PMS_BIN" | grep 'jp-reply')
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC4: one match" || return 1
  assert_contains "$c" "issue comment 42 " "AC4: #42 matches issue 42 (whole token)" || return 1
}

test_pms_poll_falls_back_to_the_sole_pending_ask_when_no_token() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000101.000100|$PMS_JP|option B please"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  local c; c=$(gh_calls "$PMS_BIN" | grep 'jp-reply')
  assert_contains "$c" "issue comment 42" "AC4: sole pending ask receives the token-less reply" || return 1
  assert_contains "$c" "jp-reply (slack): option B please" "AC4: text present" || return 1
}

test_pms_poll_comment_is_verbatim_and_reacts_and_marks_answered() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  local text='#42 Go with B & keep "quotes" $HOME `x` 100%'
  pms_history "1700000101.000100|$PMS_JP|$text"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  assert_contains "$(gh_calls "$PMS_BIN")" "**[project-manager] NOTE** jp-reply (slack): $text" "AC4: exact comment, text verbatim" || return 1
  assert_eq "$(pms_n reactions.add)" 1 "AC4: one reaction" || return 1
  local r; r=$(pms_lines reactions.add)
  assert_contains "$r" "white_check_mark" "AC4: :white_check_mark: reaction" || return 1
  assert_contains "$r" "1700000101.000100" "AC4: reaction is on JP's message" || return 1
  assert_contains "$r" "DTEST1" "AC4: reaction in the DM channel" || return 1
  # marked answered => not matched again, and a re-ask is allowed (covered above); a later token-less
  # message must NOT be attached to the answered ask:
  pms_history "1700000102.000100|$PMS_JP|another thought"  "1700000101.000100|$PMS_JP|$text"
  pms_run poll
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC4: answered ask is closed — no second jp-reply comment" || return 1
}

test_pms_poll_handles_several_jp_messages_in_one_poll() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42; pms_ask "$PMS_REPO_B" 43
  pms_history "1700000102.000100|$PMS_JP|#43 answer for b" "1700000101.000100|$PMS_JP|#42 answer for a"
  pms_run poll
  assert_eq "$(pms_gh_n 'jp-reply')" 2 "AC4: both replies commented" || return 1
  assert_eq "$(pms_n reactions.add)" 2 "AC4: both reacted" || return 1
}

# ---------------------------------------------------------------- AC5
# Each ambiguity shape: no comment, no reaction, exactly one top-level clarifying reply, not repeated.
pms_check_ambiguous() {  # pms_check_ambiguous <label> <message-text> <n-asks: 1|2>
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  [ "$3" = 2 ] && pms_ask "$PMS_REPO_B" 43
  local base_posts base_comments; base_posts=$(pms_n chat.postMessage); base_comments=$(pms_gh_n 'issue comment')
  pms_history "1700000101.000100|$PMS_JP|$2"
  pms_run poll
  assert_exit0 "$PMS_RC" "AC5 [$1]: poll ($PMS_OUT)" || return 1
  assert_eq "$(pms_gh_n 'jp-reply')" 0 "AC5 [$1]: no jp-reply comment" || return 1
  assert_eq "$(pms_gh_n 'issue comment')" "$base_comments" "AC5 [$1]: no issue comment at all" || return 1
  assert_eq "$(( $(pms_n chat.postMessage) - base_posts ))" 1 "AC5 [$1]: exactly one clarifying reply" || return 1
  local line; line=$(pms_lines chat.postMessage | tail -n 1)
  assert_not_contains "$line" "thread_ts" "AC5 [$1]: reply is top-level" || return 1
  printf '%s' "$line" | grep -qi 'which issue' || { fail "AC5 [$1]: reply must ask which issue: $line"; return 1; }
  pms_run poll
  assert_eq "$(( $(pms_n chat.postMessage) - base_posts ))" 1 "AC5 [$1]: not repeated on the next poll" || return 1
  assert_eq "$(pms_gh_n 'jp-reply')" 0 "AC5 [$1]: still no comment after the second poll" || return 1
}
test_pms_ambiguous_no_token_two_pending()   { pms_check_ambiguous no-token-two-pending "which one is this about? just do A" 2; }
test_pms_ambiguous_unknown_token_two_pending() { pms_check_ambiguous unknown-999-two-pending "#999 yes do it" 2; }
test_pms_unknown_token_does_not_fall_back_to_sole_pending() { pms_check_ambiguous unknown-999-one-pending "#999 yes do it" 1; }

# ---------------------------------------------------------------- AC6
test_pms_second_poll_rereads_nothing() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000101.000100|$PMS_JP|#42 first"
  pms_run poll
  pms_run poll
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC6: no duplicate comment on the second poll" || return 1
  assert_eq "$(pms_n reactions.add)" 1 "AC6: no duplicate reaction" || return 1
  assert_eq "$(pms_n conversations.history)" 2 "AC6: both polls did read history (non-vacuous)" || return 1
  assert_contains "$(pms_lines conversations.history | tail -n 1)" "1700000101.000100" "AC6: second poll reads newer-than the stored last-read ts" || return 1
}

test_pms_last_read_advances_past_ignored_messages_too() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000105.000100|$PMS_BOT|bot noise"
  pms_run poll
  assert_contains "$( pms_history "1700000105.000100|$PMS_BOT|bot noise"; pms_run poll; pms_lines conversations.history | tail -n 1)" "1700000105.000100" "AC6: last-read is the newest ts seen, ignored or not" || return 1
}

test_pms_last_read_does_not_advance_on_ok_false() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42; pms_ask "$PMS_REPO_B" 43
  pms_history "1700000100.000100|$PMS_JP|#42 first"
  pms_run poll                                              # last-read := ...100
  echo '{"ok":false,"error":"ratelimited","messages":[{"type":"message","user":"'"$PMS_JP"'","text":"#43 lost","ts":"1700000300.000100"}]}' \
    > "$PMS_DATA/resp-conversations.history"
  pms_run poll                                              # must not advance, must not comment
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "AC6: nothing commented from an ok:false response" || return 1
  pms_history "1700000300.000100|$PMS_JP|#43 arrived later" "1700000200.000100|$PMS_JP|#43 in between" "1700000100.000100|$PMS_JP|#42 first"
  pms_run poll
  local last; last=$(pms_lines conversations.history | tail -n 1)
  assert_contains "$last" "1700000100.000100" "AC6: after the failed poll, still reading newer than the OLD last-read ts" || return 1
  assert_eq "$(pms_gh_n 'jp-reply (slack): #43 in between')" 1 "AC6: the message from the window of the failed poll is not lost" || return 1
  assert_eq "$(pms_gh_n 'jp-reply (slack): #42 first')" 1 "AC6: and #42 was not duplicated" || return 1
}

test_pms_poll_curl_failure_does_not_advance_last_read() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  : > "$PMS_DATA/fail-conversations.history"
  pms_run poll
  rm -f "$PMS_DATA/fail-conversations.history"
  pms_history "1700000101.000100|$PMS_JP|#42 hello"
  pms_run poll
  assert_eq "$(pms_gh_n 'jp-reply (slack): #42 hello')" 1 "AC6: a poll after a curl failure still sees the message" || return 1
}

test_pms_overlapping_polls_do_not_double_comment() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42
  pms_history "1700000101.000100|$PMS_JP|#42 once only"
  : > "$PMS_DATA/slow-conversations.history"
  local p1 p2
  ( cd "$PMS_HOME" && env PIPE="$PMS_PIPE" QUEUE="$PMS_PIPE/queue" LOGDIR="$PMS_HOME/logs/pipeline" HOME="$PMS_HOME" PMS_DATA="$PMS_DATA" \
      PM_SLACK_BOT_TOKEN=fake-not-a-real-token PM_SLACK_USER_ID="$PMS_JP" FAKE_NOW="$PMS_NOW" "$RS_PMS/pm-slack.sh" poll ) >/dev/null 2>&1 </dev/null & p1=$!
  ( cd "$PMS_HOME" && env PIPE="$PMS_PIPE" QUEUE="$PMS_PIPE/queue" LOGDIR="$PMS_HOME/logs/pipeline" HOME="$PMS_HOME" PMS_DATA="$PMS_DATA" \
      PM_SLACK_BOT_TOKEN=fake-not-a-real-token PM_SLACK_USER_ID="$PMS_JP" FAKE_NOW="$PMS_NOW" "$RS_PMS/pm-slack.sh" poll ) >/dev/null 2>&1 </dev/null & p2=$!
  wait "$p1" "$p2"
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "spec: overlapping polls comment exactly once" || return 1
  assert_eq "$(pms_n reactions.add)" 1 "spec: overlapping polls react exactly once" || return 1
}

# ---------------------------------------------------------------- AC7
test_pms_no_token_is_a_silent_noop_for_both_subcommands() {
  local sub
  for sub in ask poll; do
    pms_setup
    PMS_TOKEN=""
    # the old, renamed token must not be picked up either
    if [ "$sub" = ask ]; then
      PMS_OUT=$( cd "$PMS_HOME" && env -u PM_SLACK_BOT_TOKEN PIPE="$PMS_PIPE" HOME="$PMS_HOME" PMS_DATA="$PMS_DATA" SLACK_BOT_TOKEN=legacy-fake \
        "$RS_PMS/pm-slack.sh" ask "$PMS_REPO_A" 42 "text" 2>&1 </dev/null ); PMS_RC=$?
    else
      PMS_OUT=$( cd "$PMS_HOME" && env -u PM_SLACK_BOT_TOKEN PIPE="$PMS_PIPE" HOME="$PMS_HOME" PMS_DATA="$PMS_DATA" SLACK_BOT_TOKEN=legacy-fake \
        "$RS_PMS/pm-slack.sh" poll 2>&1 </dev/null ); PMS_RC=$?
    fi
    unset PMS_TOKEN
    assert_exit0 "$PMS_RC" "AC7 [$sub]: exits 0" || return 1
    assert_eq "$PMS_OUT" "" "AC7 [$sub]: silent" || return 1
    assert_eq "$(wc -l < "$PMS_DATA/calls.log" | tr -d ' ')" 0 "AC7 [$sub]: zero curl calls" || return 1
    assert_eq "$(pms_gh_n '')" 0 "AC7 [$sub]: zero gh calls" || return 1
    assert_eq "$(find "$PMS_PIPE" -type f | wc -l | tr -d ' ')" 0 "AC7 [$sub]: no state written under PIPE" || return 1
  done
}

test_pms_empty_token_is_also_a_noop() {
  pms_setup
  PMS_TOKEN=""; pms_ask "$PMS_REPO_A" 42; unset PMS_TOKEN
  assert_exit0 "$PMS_RC" "AC7: empty PM_SLACK_BOT_TOKEN exits 0" || return 1
  assert_eq "$(wc -l < "$PMS_DATA/calls.log" | tr -d ' ')" 0 "AC7: empty token, zero curl calls" || return 1
}

# ---------------------------------------------------------------- AC8
test_pms_supervisor_has_backgrounded_poll_after_reconcile() {
  local sup="$RS_PMS/supervisor.sh" line rec pm ex
  grep -qF '( "$HERE/pm-slack.sh" poll >/dev/null 2>&1 & ) 9>&- || true' "$sup" || { fail "AC8: supervisor.sh must contain the exact backgrounded poll line with 9>&-"; return 1; }
  rec=$(grep -nF 'reconcile-status.sh" >/dev/null' "$sup" | head -n 1 | cut -d: -f1)
  pm=$(grep -nF 'pm-slack.sh" poll' "$sup" | head -n 1 | cut -d: -f1)
  ex=$(grep -n '^exec 9>&-' "$sup" | head -n 1 | cut -d: -f1)
  assert_ne "$rec" "" "AC8: reconcile step found" || return 1
  [ "$pm" -gt "$rec" ] && [ "$pm" -lt "$ex" ] || { fail "AC8: poll step must sit after the reconcile step and before 'exec 9>&-' (rec=$rec pm=$pm exec=$ex)"; return 1; }
}

# ---------------------------------------------------------------- AC9
pms_pm_section() {  # text of the "Asking JP" section (heading line to the next heading of same-or-higher level)
  awk '
    !on && /^#+[[:space:]].*Asking JP/ { on=1; match($0,/^#+/); lvl=RLENGTH; print; next }
    on { if (match($0,/^#+[[:space:]]/) && RLENGTH-1 <= lvl) exit; print }
  ' "$ROOT_PMS/agents/project-manager.md"
}

test_pms_project_manager_has_asking_jp_section_with_the_rules() {
  local s; s=$(pms_pm_section)
  [ -n "$s" ] || { fail "AC9: agents/project-manager.md needs an 'Asking JP' heading"; return 1; }
  assert_contains "$s" "pm-slack.sh ask" "AC9: how to ask" || return 1
  assert_contains "$s" "pm-slack.sh poll" "AC9: poll first each cycle" || return 1
  assert_contains "$s" "jp-reply (slack)" "AC9: reads jp-reply (slack) notes" || return 1
  assert_contains "$s" "JP CONFIRMED" "AC9: a resolving reply becomes JP CONFIRMED" || return 1
  assert_contains "$s" "Resolves:" "AC9: with a Resolves: line" || return 1
  assert_contains "$s" "FYI" "AC9: never status/FYI" || return 1
  assert_contains "$s" "one message per item" "AC9: one message per item" || return 1
  assert_contains "$s" "mockup" "AC9: mockup approval still needs JP's own GitHub comment" || return 1
  assert_contains "$s" "GitHub comment" "AC9: go/prod need JP's own GitHub comment" || return 1
  assert_contains "$s" "link" "AC9: the DM includes the direct issue link for those" || return 1
}

test_pms_jp_only_list_no_longer_lists_slack_to_jp() {
  local f="$ROOT_PMS/agents/project-manager.md" p
  assert_not_contains "$(cat "$f")" "sending email, Slack or any external message" "AC9: old blanket ban removed" || return 1
  p=$(grep -F 'JP-only, these may block' "$f")
  assert_ne "$p" "" "AC9: JP-only paragraph still present" || return 1
  assert_contains "$p" "Asking JP" "AC9: JP-only list carves out the DM and points at 'Asking JP'" || return 1
}

# ---------------------------------------------------------------- AC10
test_pms_config_example_documents_both_env_vars_with_placeholders() {
  local f="$RS_PMS/config.local.example.sh"
  grep -Eq '^#? *PM_SLACK_BOT_TOKEN=' "$f" || { fail "AC10: PM_SLACK_BOT_TOKEN documented"; return 1; }
  grep -Eq '^#? *PM_SLACK_USER_ID=' "$f" || { fail "AC10: PM_SLACK_USER_ID documented"; return 1; }
  ! grep -Eq 'xox[a-z]-|U0A8FPA9V0E' "$f" || { fail "AC10: placeholders only — no real token or JP's id in a tracked file"; return 1; }
}

test_pms_readme_describes_the_renamed_token() {
  grep -q 'PM_SLACK_BOT_TOKEN' "$ROOT_PMS/README.md" || { fail "AC10: README must describe PM_SLACK_BOT_TOKEN (SLACK_BOT_TOKEN was renamed)"; return 1; }
}

run_test test_pms_ask_posts_one_top_level_message_and_comments_once
run_test test_pms_ask_defaults_to_jp_user_id
run_test test_pms_ask_slack_errors_exit_nonzero_and_record_nothing
run_test test_pms_second_ask_while_open_is_a_noop
run_test test_pms_ask_for_another_issue_is_independent
run_test test_pms_one_reminder_after_24h_then_never
run_test test_pms_reminder_clock_starts_at_the_ask_not_at_the_last_call
run_test test_pms_new_ask_allowed_after_jp_answered
run_test test_pms_poll_ignores_bot_and_other_users
run_test test_pms_poll_only_accepts_the_configured_user_id
run_test test_pms_poll_matches_token_to_the_right_ask_among_several
run_test test_pms_poll_token_boundary_42_is_not_4
run_test test_pms_poll_falls_back_to_the_sole_pending_ask_when_no_token
run_test test_pms_poll_comment_is_verbatim_and_reacts_and_marks_answered
run_test test_pms_poll_handles_several_jp_messages_in_one_poll
run_test test_pms_ambiguous_no_token_two_pending
run_test test_pms_ambiguous_unknown_token_two_pending
run_test test_pms_unknown_token_does_not_fall_back_to_sole_pending
run_test test_pms_second_poll_rereads_nothing
run_test test_pms_last_read_advances_past_ignored_messages_too
run_test test_pms_last_read_does_not_advance_on_ok_false
run_test test_pms_poll_curl_failure_does_not_advance_last_read
run_test test_pms_overlapping_polls_do_not_double_comment
run_test test_pms_no_token_is_a_silent_noop_for_both_subcommands
run_test test_pms_empty_token_is_also_a_noop
run_test test_pms_supervisor_has_backgrounded_poll_after_reconcile
run_test test_pms_project_manager_has_asking_jp_section_with_the_rules
run_test test_pms_jp_only_list_no_longer_lists_slack_to_jp
run_test test_pms_config_example_documents_both_env_vars_with_placeholders
run_test test_pms_readme_describes_the_renamed_token
