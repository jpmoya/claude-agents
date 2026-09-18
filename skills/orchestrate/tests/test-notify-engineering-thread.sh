# Issue #15 — thread pipeline events back into the Slack thread that dispatched the run.
#
# AC3 — slack_thread_for <repo> <issue> prints "<channel> <ts>" for the LAST issue comment whose
#       first line matches `**[pipeline-bridge] NOTE** slack-thread: <channel>:<ts>`, provided that
#       channel equals $SLACK_ENGINEERING_CHANNEL.
# AC4 — ...and prints nothing when no comment matches, or the last match is for another channel.
# AC5 — notify_engineering adds `thread_ts` to the Slack payload only when slack_thread_for is
#       non-empty; otherwise the payload is byte-identical to today's (no thread_ts key).
# AC7 — (supervisor.sh half) the new/changed functions use none of $FORBIDDEN_RE's constructs.
#
# How the functions are reached: supervisor.sh is a top-level cron tick (lock, dispatch loops) and
# cannot be sourced without running it, so this file extracts every column-0 function definition
# from it (net_fn_defs below — defining a function has no side effects) and loads only those into a
# throwaway `bash` driver running under the same `set -uo pipefail` supervisor.sh uses.
# CONVENTION THE DEVELOPER MUST KEEP: slack_thread_for and notify_engineering stay column-0
# `name() {` ... `}` definitions in supervisor.sh.
#
# Interface assumptions (the ticket leaves these open; recorded in the handoff):
#   * notify_engineering keeps its existing 4-arg signature (issue emoji reason owner/repo) — the
#     thread lookup therefore has only "owner/repo" + issue to go on, so slack_thread_for's first
#     arg is that owner/repo string (fetched with `gh issue view <issue> --repo <owner/repo>
#     --json comments`); a cd-into-a-local-checkout lookup cannot work from notify_engineering.
#   * exit status of slack_thread_for is not pinned; only its stdout is.
#
# Fakes: a fake `gh` (canned `issue view` comments; logs every call) and a fake `curl` (writes the
# `-d` payload of the chat.postMessage call to a file, answers {"ok":true}) are installed into a
# per-test temp dir that is first on PATH. Fixtures use placeholder repo/channel names only (this
# repo is public); the "token" is an obviously-fake non-token-shaped string (AC17's gitleaks scan).
#
# Vacuity guard: every "returns empty / no thread_ts" case ALSO asserts the fake gh was asked for
# the issue's comments — otherwise a stub that never looks anything up would pass the negative.

HERE_NET=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUPERVISOR_NET="$HERE_NET/../supervisor.sh"

NET_REPO="example-owner/project-a"
NET_ISSUE=42
NET_TOKEN="unmistakable-fake-slack-credential-for-tests-only"

# net_fn_defs [name] — prints the column-0 function definitions found in supervisor.sh (all of
# them, or just <name>'s). One-liner definitions and multi-line ones (ending at a column-0 `}`)
# are both handled.
net_fn_defs() {
  awk -v want="${1:-}" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {
      name = $0; sub(/\(\).*/, "", name)
      emit = (want == "" || want == name)
      if (emit) print
      if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*(#.*)?$/) infn = 0; else infn = 1
      next
    }
    infn { if (emit) print; if ($0 ~ /^\}/) infn = 0 }
  ' "$SUPERVISOR_NET"
}

# net_mk_gh <dir> — fake gh. `gh issue view ... [--json ...] [--jq|-q expr]` answers from
# <dir>/comments.json (a JSON array of comments) as {"state":"OPEN","comments":[...]}, applying
# the caller's --jq/-q expression with the real jq if one is given. <dir>/gh-view-rc (default 0)
# makes `issue view` fail. Every call is logged, one line, to <dir>/gh-calls.log.
net_mk_gh() {
  local dir=$1
  : > "$dir/gh-calls.log"
  cat > "$dir/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  rc=$(cat "$HERE/gh-view-rc" 2>/dev/null || echo 0)
  [ "$rc" -eq 0 ] || exit "$rc"
  json=$(jq -c '{state: "OPEN", comments: .}' "$HERE/comments.json")
  expr="" prev=""
  for a in "$@"; do
    if [ "$prev" = "--jq" ] || [ "$prev" = "-q" ]; then expr=$a; fi
    prev=$a
  done
  if [ -n "$expr" ]; then printf '%s' "$json" | jq -r "$expr"; else printf '%s\n' "$json"; fi
  exit 0
fi
echo "fake gh: unexpected invocation: $*" >&2
exit 1
GH_EOF
  chmod +x "$dir/gh"
}

# net_mk_curl <dir> — fake curl. The `-d`/`--data*` value of a chat.postMessage call is written
# verbatim (no added newline) to <dir>/slack-payload; each such call appends a line to
# <dir>/slack-posts. Replies {"ok":true} so notify_engineering logs a success and stays quiet.
net_mk_curl() {
  local dir=$1
  : > "$dir/slack-posts"
  cat > "$dir/curl" <<'CURL_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
url="" data="" prev=""
for a in "$@"; do
  case "$prev" in -d|--data|--data-raw|--data-binary) data=$a ;; esac
  case "$a" in http://*|https://*) url=$a ;; esac
  prev=$a
done
case "$url" in
  *chat.postMessage*)
    printf '%s' "$data" > "$HERE/slack-payload"
    echo posted >> "$HERE/slack-posts"
    echo '{"ok":true}'
    ;;
  *) echo '{}' ;;
esac
exit 0
CURL_EOF
  chmod +x "$dir/curl"
}

# net_set_comments <dir> <body...> — writes <dir>/comments.json: one comment per arg, in order,
# with strictly increasing createdAt (so "last" by array order and by time agree).
net_set_comments() {
  local dir=$1; shift
  local arr='[]' i=0 b
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq -c --arg b "$b" --arg t "$(printf '2026-09-18T10:00:%02dZ' "$i")" \
      '. + [{body: $b, createdAt: $t, author: {login: "example-user"}}]')
  done
  printf '%s' "$arr" > "$dir/comments.json"
}

# net_run <mode> <env-channel> <gh-view-rc> <bodies...> — builds the fake tree, runs either
#   mode=thread : slack_thread_for "$NET_REPO" "$NET_ISSUE"          -> NET_OUT = its stdout
#   mode=notify : notify_engineering 42 ":white_check_mark:" "Deployed" "$NET_REPO"
# and captures NET_GH_CALLS (fake gh call log), NET_PAYLOAD (posted payload, "" if none),
# NET_POSTS (number of chat.postMessage calls) — all read before the temp dir is removed.
# <env-channel> is the value of SLACK_ENGINEERING_CHANNEL for the run.
net_run() {
  local mode=$1 chan=$2 view_rc=$3; shift 3
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-net.XXXXXX")
  net_mk_gh "$dir"; net_mk_curl "$dir"
  echo "$view_rc" > "$dir/gh-view-rc"
  net_set_comments "$dir" "$@"
  net_fn_defs > "$dir/fns.sh"
  cat > "$dir/driver.sh" <<'DRV_EOF'
set -uo pipefail
. "$NET_DIR/fns.sh"
if [ "$NET_MODE" = "thread" ]; then
  slack_thread_for "$NET_REPO" "$NET_ISSUE"
else
  notify_engineering "$NET_ISSUE" ":white_check_mark:" "Deployed" "$NET_REPO"
fi
DRV_EOF
  NET_OUT=$(env PATH="$dir:$PATH" NET_DIR="$dir" NET_MODE="$mode" NET_REPO="$NET_REPO" NET_ISSUE="$NET_ISSUE" \
    SLOG="$dir/supervisor.log" SLACK_BOT_TOKEN="$NET_TOKEN" SLACK_ENGINEERING_CHANNEL="$chan" \
    bash "$dir/driver.sh" 2>"$dir/stderr")
  NET_GH_CALLS=$(cat "$dir/gh-calls.log" 2>/dev/null)
  NET_PAYLOAD=$(cat "$dir/slack-payload" 2>/dev/null)
  NET_POSTS=$(wc -l < "$dir/slack-posts" | tr -d ' ')
  rm -rf "$dir"
}

# net_assert_lookup_made <label> — the run must have asked gh for THIS issue's comments in THIS repo.
net_assert_lookup_made() {
  local line
  line=$(printf '%s\n' "$NET_GH_CALLS" | grep -E "^issue view( .*)? $NET_ISSUE( |\$)" | head -1)
  [ -n "$line" ] || { fail "$1: gh was never asked for 'issue view ... $NET_ISSUE ...' (calls: [$NET_GH_CALLS])"; return 1; }
  assert_contains "$line" "comments" "$1: the lookup must request the issue's comments" || return 1
  case "$line" in
    *"--repo $NET_REPO"*|*"-R $NET_REPO"*) : ;;
    *) fail "$1: the lookup must target $NET_REPO via --repo/-R (notify_engineering only knows owner/repo, and the supervisor's cwd is not a checkout): [$line]"; return 1 ;;
  esac
}

NET_NOTE_C1_111='**[pipeline-bridge] NOTE** slack-thread: C1:111'
NET_NOTE_C1_222='**[pipeline-bridge] NOTE** slack-thread: C1:222'
NET_NOTE_C2_999='**[pipeline-bridge] NOTE** slack-thread: C2:999'

# ---------------------------------------------------------------------------
# AC3 — slack_thread_for returns "<channel> <ts>" of the last matching NOTE (channel matches)
# ---------------------------------------------------------------------------

test_net_ac3_single_matching_note_returns_channel_and_ts() {
  # Ticket fixture: last matching line is `... slack-thread: C1:111` -> `C1 111`.
  net_run thread C1 0 \
    '**[product-manager] READY FOR ENGINEERING**' \
    "$NET_NOTE_C1_111" \
    '**[supervisor] NOTE** claim: host 2026-09-18T10:00:00Z'
  net_assert_lookup_made "AC3" || return 1
  assert_eq "$NET_OUT" "C1 111" "AC3: the recorded channel and ts, space-separated" || return 1
}

test_net_ac3_realistic_dotted_ts_is_kept_whole() {
  # Slack ts values look like <epoch>.<counter>; only the FIRST colon separates channel from ts.
  net_run thread C0123ABCD 0 '**[pipeline-bridge] NOTE** slack-thread: C0123ABCD:1726690000.000200'
  net_assert_lookup_made "AC3" || return 1
  assert_eq "$NET_OUT" "C0123ABCD 1726690000.000200" "AC3: dotted ts must survive intact" || return 1
}

test_net_ac3_two_matches_the_later_comment_wins() {
  # Ticket fixture: same issue mentioned from two threads -> the later one (comment order) wins.
  net_run thread C1 0 "$NET_NOTE_C1_111" 'a human comment in between' "$NET_NOTE_C1_222"
  net_assert_lookup_made "AC3" || return 1
  assert_eq "$NET_OUT" "C1 222" "AC3: last matching NOTE wins" || return 1
}

test_net_ac3_only_the_first_line_of_the_body_is_matched() {
  # "first line matches": extra detail lines after a matching first line are fine...
  net_run thread C1 0 "$NET_NOTE_C1_111"$'\n''extra detail line'
  net_assert_lookup_made "AC3" || return 1
  assert_eq "$NET_OUT" "C1 111" "AC3: a matching first line with a longer body still counts" || return 1
}

# ---------------------------------------------------------------------------
# AC4 — empty when nothing matches / when the last match is for another channel
# ---------------------------------------------------------------------------

test_net_ac4_no_comments_at_all_returns_empty() {
  # Boundary: zero comments (issue dispatched by hand).
  net_run thread C1 0
  net_assert_lookup_made "AC4" || return 1
  assert_eq "$NET_OUT" "" "AC4: no comments -> nothing printed" || return 1
}

test_net_ac4_no_matching_note_returns_empty() {
  # Ticket negative: comments exist but none is a slack-thread NOTE. Includes near-misses: another
  # NOTE kind, a routing marker, and a slack-thread line that is NOT the first line of its comment.
  net_run thread C1 0 \
    '**[product-manager] READY FOR ENGINEERING**' \
    '**[supervisor] NOTE** claim: host 2026-09-18T10:00:00Z' \
    'JP: please look at this'$'\n''**[pipeline-bridge] NOTE** slack-thread: C1:111'
  net_assert_lookup_made "AC4" || return 1
  assert_eq "$NET_OUT" "" "AC4: no first-line match -> nothing printed" || return 1
}

test_net_ac4_only_match_is_for_another_channel_returns_empty() {
  # Ticket negative (defensive): never thread into a channel that is not #engineering.
  net_run thread C1 0 "$NET_NOTE_C2_999"
  net_assert_lookup_made "AC4" || return 1
  assert_eq "$NET_OUT" "" "AC4: recorded channel C2 != SLACK_ENGINEERING_CHANNEL C1 -> nothing printed" || return 1
}

test_net_ac4_last_match_is_other_channel_does_not_fall_back_to_earlier() {
  # Expected Behavior 4: "finds the LAST matching comment, and if ITS recorded channel equals
  # $SLACK_ENGINEERING_CHANNEL, prints" — last wins first, channel check second. Earlier C1:111
  # must not resurface just because the later C2:999 is rejected.
  net_run thread C1 0 "$NET_NOTE_C1_111" "$NET_NOTE_C2_999"
  net_assert_lookup_made "AC4" || return 1
  assert_eq "$NET_OUT" "" "AC4: last match (C2:999) rejected -> nothing printed, not the earlier C1:111" || return 1
}

# ---------------------------------------------------------------------------
# AC5 — notify_engineering's payload: thread_ts only when the lookup is non-empty
# ---------------------------------------------------------------------------

# Hand-written "before" payload: exactly what supervisor.sh's existing
#   jq -n --arg ch ... --arg txt ... '{channel: $ch, text: $txt, unfurl_links: false}'
# prints for issue 42 in example-owner/project-a with reason "Deployed" (jq's default 2-space
# pretty-print, key order channel/text/unfurl_links). Written by hand, not recorded from the code.
net_baseline_payload() {
  printf '%s\n' \
    '{' \
    '  "channel": "C1",' \
    '  "text": ":white_check_mark: <https://github.com/example-owner/project-a/issues/42|#42> — Deployed",' \
    '  "unfurl_links": false' \
    '}'
}

test_net_ac5_thread_match_adds_thread_ts_and_changes_nothing_else() {
  net_run notify C1 0 "$NET_NOTE_C1_111"
  local ts_type ts_val rest expected_rest
  assert_eq "$NET_POSTS" "1" "AC5: exactly one Slack post" || return 1
  net_assert_lookup_made "AC5" || return 1
  # ticket: the captured payload contains "thread_ts":"111" (whitespace-tolerant: the payload may be pretty or compact JSON)
  printf '%s' "$NET_PAYLOAD" | grep -Eq '"thread_ts"[[:space:]]*:[[:space:]]*"111"' \
    || { fail "AC5: payload must contain \"thread_ts\":\"111\" — got: $NET_PAYLOAD"; return 1; }
  ts_type=$(printf '%s' "$NET_PAYLOAD" | jq -r '.thread_ts | type')
  ts_val=$(printf '%s' "$NET_PAYLOAD" | jq -r '.thread_ts')
  assert_eq "$ts_type" "string" "AC5: thread_ts is a JSON string (Slack ts), not a number" || return 1
  assert_eq "$ts_val" "111" "AC5: thread_ts value" || return 1
  # everything except thread_ts is exactly today's payload
  rest=$(printf '%s' "$NET_PAYLOAD" | jq -c 'del(.thread_ts)')
  expected_rest=$(net_baseline_payload | jq -c .)
  assert_eq "$rest" "$expected_rest" "AC5: channel/text/unfurl_links unchanged" || return 1
}

test_net_ac5_no_note_payload_is_byte_identical_to_today() {
  net_run notify C1 0 '**[product-manager] READY FOR ENGINEERING**'
  assert_eq "$NET_POSTS" "1" "AC5: exactly one Slack post" || return 1
  net_assert_lookup_made "AC5" || return 1   # the lookup must have happened and come back empty
  assert_eq "$NET_PAYLOAD" "$(net_baseline_payload)" "AC5: payload byte-identical to the hand-written 'before' payload" || return 1
  assert_not_contains "$NET_PAYLOAD" "thread_ts" "AC5: no thread_ts key at all" || return 1
}

test_net_ac5_note_for_other_channel_payload_is_byte_identical_to_today() {
  net_run notify C1 0 "$NET_NOTE_C2_999"
  assert_eq "$NET_POSTS" "1" "AC5: exactly one Slack post" || return 1
  net_assert_lookup_made "AC5" || return 1
  assert_eq "$NET_PAYLOAD" "$(net_baseline_payload)" "AC5: a NOTE for another channel must not thread — payload byte-identical to today's" || return 1
}

test_net_ac5_two_notes_the_later_thread_is_used() {
  net_run notify C1 0 "$NET_NOTE_C1_111" "$NET_NOTE_C1_222"
  net_assert_lookup_made "AC5" || return 1
  assert_eq "$(printf '%s' "$NET_PAYLOAD" | jq -r '.thread_ts // "absent"')" "222" "AC5: last matching NOTE's ts is used" || return 1
}

test_net_ac5_lookup_failure_still_posts_the_flat_message() {
  # Derived from AC5 "otherwise the payload is unchanged": if gh can't be reached, the alert must
  # still go out flat (unthreaded) rather than being dropped.
  net_run notify C1 1 "$NET_NOTE_C1_111"
  assert_eq "$NET_POSTS" "1" "AC5: the Slack post still happens when the comment lookup fails" || return 1
  net_assert_lookup_made "AC5" || return 1
  assert_eq "$NET_PAYLOAD" "$(net_baseline_payload)" "AC5: failed lookup -> payload identical to today's" || return 1
}

# ---------------------------------------------------------------------------
# AC7 (supervisor.sh half) — portability: no forbidden construct in the new/changed functions.
# supervisor.sh as a whole legitimately mentions the guarded lock helpers, so only the two
# functions this ticket adds/changes are scanned. Paired with a positive requirement so an
# empty/stub body cannot pass vacuously.
# ---------------------------------------------------------------------------

test_net_ac7_slack_thread_for_and_notify_are_portable() {
  if [ -z "${FORBIDDEN_RE:-}" ]; then
    fail "AC7: \$FORBIDDEN_RE not set — expected test-ac11-portability.sh to run first (run-tests.sh sources test-*.sh alphabetically)"
    return 1
  fi
  local st nt hits
  st=$(net_fn_defs slack_thread_for)
  nt=$(net_fn_defs notify_engineering)
  assert_ne "$nt" "" "AC7: notify_engineering must remain a column-0 function in supervisor.sh" || return 1
  # positive: slack_thread_for must actually fetch the issue's comments (ticket fixture: `gh issue view --json comments`)
  assert_contains "$st" "gh issue view" "AC7: slack_thread_for must fetch the comments via gh issue view" || return 1
  assert_contains "$st" "comments" "AC7: slack_thread_for must request the comments field" || return 1
  hits=$(printf '%s\n%s\n' "$st" "$nt" | grep -nE "$FORBIDDEN_RE" || true)
  assert_eq "$hits" "" "AC7: slack_thread_for/notify_engineering must contain none of the non-macOS-bash-3.2-safe constructs" || return 1
}

run_test test_net_ac3_single_matching_note_returns_channel_and_ts
run_test test_net_ac3_realistic_dotted_ts_is_kept_whole
run_test test_net_ac3_two_matches_the_later_comment_wins
run_test test_net_ac3_only_the_first_line_of_the_body_is_matched
run_test test_net_ac4_no_comments_at_all_returns_empty
run_test test_net_ac4_no_matching_note_returns_empty
run_test test_net_ac4_only_match_is_for_another_channel_returns_empty
run_test test_net_ac4_last_match_is_other_channel_does_not_fall_back_to_earlier
run_test test_net_ac5_thread_match_adds_thread_ts_and_changes_nothing_else
run_test test_net_ac5_no_note_payload_is_byte_identical_to_today
run_test test_net_ac5_note_for_other_channel_payload_is_byte_identical_to_today
run_test test_net_ac5_two_notes_the_later_thread_is_used
run_test test_net_ac5_lookup_failure_still_posts_the_flat_message
run_test test_net_ac7_slack_thread_for_and_notify_are_portable
