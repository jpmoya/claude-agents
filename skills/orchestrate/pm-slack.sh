#!/bin/bash
# pm-slack.sh — the delivery-lead <-> JP Slack DM bridge (issue #117). Deterministic, no LLM.
#   pm-slack.sh ask <owner/repo> <issue> <text> [kind]   post ONE top-level DM asking JP to unblock <issue>
#   pm-slack.sh poll                                     copy JP's DM replies onto the issues they answer, then remind
#                                                        JP once of every ask still open after 24h (#677, remind_sweep)
# Needs PM_SLACK_BOT_TOKEN (config.local.sh); without it both subcommands are a silent no-op.
# PM_SLACK_USER_ID = JP's Slack user id (default below). It never acts on an answer — it only records it,
# EXCEPT for the one `kind=mockup-skip` bridge below (#470): a reply recognized as JP choosing to skip
# mockups is echoed onto the issue as the canonical `**[jp] SKIP MOCKUPS**` marker, a deterministic,
# verbatim echo of JP's own words — never the PM's judgment, never written for any other `kind`.
# State (machine-local): $PIPE/pm-slack/{asks.tsv,last-read,channel,lock,remind-failed}.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
source "$HERE/config.sh"
# shellcheck source=../../hooks/pipeline-markers.sh
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"

[ -n "${PM_SLACK_BOT_TOKEN:-}" ] || exit 0
JP_ID="${PM_SLACK_USER_ID:-U0A8FPA9V0E}"
REMIND_AFTER_SECS=86400
REMIND_RETRY_SECS=1800   # a sweep that failed (Slack post, or an unreadable issue state) is not retried sooner (#677)
SD="$PIPE/pm-slack"
ASKS="$SD/asks.tsv"      # repo \t issue \t channel \t ts \t asked_at \t status(open|answered) \t reminded(0|1) \t kind(""|mockup-skip, #470)
LASTREAD="$SD/last-read"
CHANNEL_FILE="$SD/channel"
LOCKDIR="$SD/lock"
TAB=$(printf '\t')

die() { echo "pm-slack: $*" >&2; exit 1; }

# slack <method> <json> — POST to the Slack Web API; sets RESP; returns 1 (message on stderr) on curl failure or ok:false.
# SLACK_FORM=1 sends $2 (a flat JSON object) form-encoded instead — read methods like conversations.history reject JSON bodies.
slack() {
  local -a body=(-H 'Content-Type: application/json; charset=utf-8' --data "$2")
  if [ -n "${SLACK_FORM:-}" ]; then
    body=(); local kv
    while IFS= read -r kv; do body+=(--data-urlencode "$kv"); done < <(printf '%s' "$2" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  fi
  RESP=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer $PM_SLACK_BOT_TOKEN" \
    "${body[@]}" "https://slack.com/api/$1" </dev/null) \
    || { echo "pm-slack: curl failed calling $1" >&2; return 1; }
  printf '%s' "$RESP" | jq -e '.ok == true' >/dev/null 2>&1 \
    || { echo "pm-slack: Slack $1 failed: $(printf '%s' "$RESP" | jq -r '.error // "bad response"' 2>/dev/null)" >&2; return 1; }
}

lock() {  # lock <wait-secs> — mkdir lock (no flock on macOS); a lock older than 10 min is a dead process
  local n=$(( $1 * 5 )) i=0
  mkdir -p "$SD" || return 1
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCKDIR" 2>/dev/null; continue; fi
    [ "$i" -ge "$n" ] && return 1
    i=$((i + 1)); sleep 0.2
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
}

write_atomic() { local f=$1 tmp; tmp=$(mktemp "$f.XXXXXX") && cat > "$tmp" && mv "$tmp" "$f"; }

# set_ask <repo> <issue> <channel> <ts> <asked_at> <status> <reminded> [kind] — replace/insert the record.
# kind (8th field, optional, empty for an ordinary free-text ask) tags what a matched reply means:
# "mockup-skip" is the only kind poll currently acts on (see cmd_poll's SKIP MOCKUPS bridge, #470).
set_ask() {
  { [ -f "$ASKS" ] && awk -F'\t' -v r="$1" -v i="$2" '!($1==r && $2==i)' "$ASKS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}"; } | write_atomic "$ASKS"
}

open_dm() {  # -> DM channel id on stdout (cached in $CHANNEL_FILE)
  slack conversations.open "$(jq -nc --arg u "$JP_ID" '{users:$u}')" || return 1
  local ch; ch=$(printf '%s' "$RESP" | jq -r '.channel.id // empty')
  [ -n "$ch" ] || { echo "pm-slack: conversations.open returned no channel" >&2; return 1; }
  printf '%s\n' "$ch" | write_atomic "$CHANNEL_FILE"
  printf '%s' "$ch"
}

post() {  # post <channel> <text> — top-level message (never a thread); sets POSTED_TS
  slack chat.postMessage "$(jq -nc --arg c "$1" --arg t "$2" '{channel:$c,text:$t}')" || return 1
  POSTED_TS=$(printf '%s' "$RESP" | jq -r '.ts // empty')
}

update_msg() {  # update_msg <channel> <ts> <text> — edit an existing top-level message in place
  slack chat.update "$(jq -nc --arg c "$1" --arg t "$2" --arg x "$3" '{channel:$c,ts:$t,text:$x}')"
}

cmd_ask() {
  [ $# -ge 3 ] || die "usage: pm-slack.sh ask <owner/repo> <issue> <text> [kind]"
  local repo=$1 issue=$2 text=$3 kind=${4:-} short=${1##*/} now cur status reminded asked_at kind_cur ch msg
  case "$issue" in ''|*[!0-9]*) die "issue must be a number" ;; esac
  lock 60 || die "another pm-slack run holds the lock"
  now=$(date +%s)
  cur=$([ -f "$ASKS" ] && awk -F'\t' -v r="$repo" -v i="$issue" '$1==r && $2==i' "$ASKS")
  if [ -n "$cur" ]; then
    IFS="$TAB" read -r _ _ ch_cur ts_cur asked_at status reminded kind_cur <<< "$cur"
    # A mockup-skip ask is a no-op once there is already any open ask on this issue (never displace an
    # unrelated question's text — e.g. a real blocker — with the mockup-skip one) or once a mockup-skip
    # ask on this issue has already been answered (never re-ask JP something he already answered, even
    # across a later re-dispatch of the same ticket with `UI change: yes` again) (#470).
    if [ "$kind" = mockup-skip ] && { [ "$status" = open ] || [ "$kind_cur" = mockup-skip ]; }; then
      exit 0
    fi
    if [ "$status" = open ]; then
      # one open ask per issue; exactly one reminder (a new top-level message) after 24h, then never again
      if [ "$reminded" = 0 ] && [ $((now - asked_at)) -ge "$REMIND_AFTER_SECS" ]; then
        ch=$(open_dm) || exit 1
        msg="#$issue · $short"$'\n'"Reminder: still waiting on your answer to the message above."$'\n\n'"Reply here with #$issue and your answer."
        post "$ch" "$msg" || exit 1
        set_ask "$repo" "$issue" "$ch" "$ts_cur" "$asked_at" open 1 "$kind_cur"
        exit 0
      fi
      # The caller's text can change before any reminder is due (e.g. "apply migrations" becomes stale
      # once that's resolved and a different blocker remains): edit the original message in place rather
      # than silently doing nothing, so JP is never looking at a stale ask (#464).
      msg="#$issue · $short"$'\n'"$text"$'\n\n'"Reply here with #$issue and your answer."
      update_msg "$ch_cur" "$ts_cur" "$msg" || exit 1
      # Re-store the record with the CALLER's kind (possibly empty/different from kind_cur), never the
      # stale stored one — otherwise an old mockup-skip ask edited into an unrelated ordinary ask would
      # keep answering to the SKIP MOCKUPS bridge forever (#470).
      set_ask "$repo" "$issue" "$ch_cur" "$ts_cur" "$asked_at" open "$reminded" "$kind"
      exit 0
    fi
  fi
  ch=$(open_dm) || exit 1
  msg="#$issue · $short"$'\n'"$text"$'\n\n'"Reply here with #$issue and your answer."
  post "$ch" "$msg" || exit 1
  [ -n "$POSTED_TS" ] || die "chat.postMessage returned no ts"
  set_ask "$repo" "$issue" "$ch" "$POSTED_TS" "$now" open 0 "$kind"
  [ -f "$LASTREAD" ] || printf '%s\n' "$POSTED_TS" | write_atomic "$LASTREAD"   # replies are read from the first ask on
  gh issue comment "$issue" --repo "$repo" --body "**[delivery-lead] NOTE** slack-ask: $POSTED_TS" >/dev/null \
    || die "ask posted (ts $POSTED_TS) but the slack-ask comment on $repo#$issue failed"
}

# remind_sweep <dm channel> — #677: the end of every poll, under the poll's lock. Due = an open ask at least REMIND_AFTER_SECS
# old that was never reminded; a mockup-skip ask is non-blocking and never due. The issue state of each due ask is read once:
# closed -> stored `answered`, no reminder; unreadable -> left for the next poll. The rest get ONE DM for the whole sweep, one
# line per ask, then reminded=1 — the flag cmd_ask's own reminder uses, so an ask is reminded once in total. A failed post
# leaves reminded=0: one tagged stderr line, one webhook alert per failure streak (tags only — never the token, the ask text
# or JP's reply). A failed sweep (post failed, or a state was unreadable) writes "<epoch> <post|read>" to remind-failed and
# is retried REMIND_RETRY_SECS later, never on every 2-minute poll: no GitHub read at all inside that window.
remind_sweep() {
  local ch=$1 now due row repo issue rch ts asked st rem kind state lines="" sent="" tags prev pkind unread=0
  now=$(date +%s)
  { read -r prev pkind < "$SD/remind-failed"; } 2>/dev/null || { prev=""; pkind=""; }
  case "$prev" in ''|*[!0-9]*) ;; *) [ $(( now - prev )) -ge "$REMIND_RETRY_SECS" ] || return 0 ;; esac
  due=$(awk -F'\t' -v now="$now" -v after="$REMIND_AFTER_SECS" '$6 == "open" && $7 == "0" && $8 != "mockup-skip" && now - $5 >= after' "$ASKS" 2>/dev/null)
  [ -n "$due" ] || { rm -f "$SD/remind-failed"; return 0; }
  while IFS= read -r row <&4; do
    IFS="$TAB" read -r repo issue rch ts asked st rem kind <<< "$row"
    state=$(gh issue view "$issue" --repo "$repo" --json state --jq .state 2>/dev/null </dev/null) || { unread=1; continue; }
    if [ "$state" = CLOSED ]; then set_ask "$repo" "$issue" "$rch" "$ts" "$asked" answered "$rem" "$kind"; continue; fi
    lines="$lines#$issue · ${repo##*/} — waiting $(( (now - asked) / 86400 ))d — https://github.com/$repo/issues/$issue"$'\n'
    sent="$sent$row"$'\n'
  done 4<<< "$due"
  if [ "$unread" = 1 ]; then echo "$now read" > "$SD/remind-failed"; else rm -f "$SD/remind-failed"; fi
  [ -n "$lines" ] || return 0
  if ! post "$ch" "Still waiting on your answer:"$'\n'"$lines"$'\n'"Reply here with #<issue> and your answer."; then
    tags="release=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown) environment=$(hostname -s 2>/dev/null || echo unknown) route=pm-slack/remind"
    echo "pm-slack: reminder post failed: $tags" >&2
    echo "$now post" > "$SD/remind-failed"
    if [ "$pkind" != post ]; then   # first failure of the streak
      [ -z "${SLACK_WEBHOOK_URL:-}" ] || curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
        --data "$(jq -nc --arg t "pm-slack reminder post failed: $tags" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
    fi
    return 0
  fi
  while IFS= read -r row <&4; do
    [ -n "$row" ] || continue
    IFS="$TAB" read -r repo issue rch ts asked st rem kind <<< "$row"
    set_ask "$repo" "$issue" "$rch" "$ts" "$asked" open 1 "$kind"
  done 4<<< "$sent"
}

unslack() { printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'; }   # Slack HTML-escapes & < >

cmd_poll() {
  lock 0 || exit 0                       # an overlapping poll is already running
  [ -f "$LASTREAD" ] || exit 0           # no ask ever made on this host
  local last ch msgs mts mtext m tokens tok matches n repo issue mch kind pend
  last=$(cat "$LASTREAD")
  ch=$(cat "$CHANNEL_FILE" 2>/dev/null); [ -n "$ch" ] || ch=$(open_dm) || exit 1
  SLACK_FORM=1 slack conversations.history "$(jq -nc --arg c "$ch" --arg o "$last" '{channel:$c,oldest:$o,limit:200}')" || exit 1
  msgs=$(printf '%s' "$RESP" | jq -c '(.messages // []) | map(select(.type=="message" and .ts)) | sort_by(.ts|tonumber) | .[]') || exit 1
  while IFS= read -r m <&3; do
    [ -n "$m" ] || continue
    mts=$(printf '%s' "$m" | jq -r '.ts')
    if [ "$(printf '%s' "$m" | jq -r '.user // ""')" = "$JP_ID" ]; then
      mtext=$(unslack "$(printf '%s' "$m" | jq -r '.text // ""')")
      pend=$(awk -F'\t' '$6=="open"' "$ASKS" 2>/dev/null)
      matches=""
      tokens=$(printf '%s' "$mtext" | grep -oE '#[0-9]+' | tr -d '#')
      if [ -n "$tokens" ]; then
        for tok in $tokens; do
          matches=$(printf '%s\n' "$pend" | awk -F'\t' -v i="$tok" '$2==i')
          [ -n "$matches" ] && break
        done
      elif [ -n "$pend" ] && [ "$(printf '%s\n' "$pend" | wc -l | tr -d ' ')" = 1 ]; then
        matches=$pend
      fi
      n=$(printf '%s' "$matches" | grep -c . )
      if [ "$n" = 1 ]; then
        IFS="$TAB" read -r repo issue mch _ _ _ _ kind <<< "$matches"
        gh issue comment "$issue" --repo "$repo" --body "**[delivery-lead] NOTE** jp-reply (slack): $mtext" >/dev/null \
          || { echo "pm-slack: comment on $repo#$issue failed" >&2; exit 1; }
        # #470: a mockup-skip ask whose reply reads as JP choosing to skip is echoed onto the issue as the
        # canonical marker, verbatim — a deterministic bridge, never the PM's own judgment and never written
        # for any other kind of ask. gh runs as JP's own account (same as every other pipeline comment), so
        # this satisfies the marker's author/exact-line/JP-said checks the same way JP's own comment would.
        # Posted BEFORE set_ask marks the record "answered" and hard-fails on error (like the NOTE above):
        # a transient gh/network failure must not lose the skip — the record stays "open" and LASTREAD
        # does not advance past this message, so the next poll retries it (a duplicate marker is harmless).
        if [ "$kind" = mockup-skip ] && is_jp_skip_mockups_reply "$mtext"; then
          gh issue comment "$issue" --repo "$repo" --body "$(skip_mockups_marker_body "$mtext")" >/dev/null \
            || { echo "pm-slack: SKIP MOCKUPS bridge comment on $repo#$issue failed" >&2; exit 1; }
        fi
        IFS="$TAB" read -r _ _ _ ats aat _ rem _ <<< "$matches"
        set_ask "$repo" "$issue" "$mch" "$ats" "$aat" answered "$rem" "$kind"
        slack reactions.add "$(jq -nc --arg c "$ch" --arg t "$mts" '{channel:$c,timestamp:$t,name:"white_check_mark"}')" \
          || echo "pm-slack: reaction failed (reply was recorded)" >&2
      else
        post "$ch" "Which issue is this about? Start your reply with #<issue> — pending: $(printf '%s\n' "$pend" | awk -F'\t' '{printf "#%s (%s) ", $2, $1}' | sed 's#[^ ]*/##g')" \
          || exit 1
      fi
    fi
    printf '%s\n' "$mts" | write_atomic "$LASTREAD"
  done 3<<< "$msgs"   # own fd: curl/gh must not eat the loop's input
  remind_sweep "$ch"   # #677: after the replies, so an ask JP just answered is never reminded
}

case "${1:-}" in
  ask)  shift; cmd_ask "$@" ;;
  poll) cmd_poll ;;
  *)    die "usage: pm-slack.sh ask <owner/repo> <issue> <text> | poll" ;;
esac
