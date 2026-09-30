#!/bin/bash
# pm-slack.sh — the project-manager <-> JP Slack DM bridge (issue #117). Deterministic, no LLM.
#   pm-slack.sh ask <owner/repo> <issue> <text>   post ONE top-level DM asking JP to unblock <issue>
#   pm-slack.sh poll                              copy JP's DM replies onto the issues they answer
# Needs PM_SLACK_BOT_TOKEN (config.local.sh); without it both subcommands are a silent no-op.
# PM_SLACK_USER_ID = JP's Slack user id (default below). It never acts on an answer — it only records it.
# State (machine-local): $PIPE/pm-slack/{asks.tsv,last-read,channel,lock}.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
source "$HERE/config.sh"

[ -n "${PM_SLACK_BOT_TOKEN:-}" ] || exit 0
JP_ID="${PM_SLACK_USER_ID:-U0A8FPA9V0E}"
REMIND_AFTER_SECS=86400
SD="$PIPE/pm-slack"
ASKS="$SD/asks.tsv"      # repo \t issue \t channel \t ts \t asked_at \t status(open|answered) \t reminded(0|1)
LASTREAD="$SD/last-read"
CHANNEL_FILE="$SD/channel"
LOCKDIR="$SD/lock"
TAB=$(printf '\t')

die() { echo "pm-slack: $*" >&2; exit 1; }

# slack <method> <json> — POST to the Slack Web API; sets RESP; returns 1 (message on stderr) on curl failure or ok:false.
slack() {
  RESP=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer $PM_SLACK_BOT_TOKEN" \
    -H 'Content-Type: application/json; charset=utf-8' --data "$2" "https://slack.com/api/$1" </dev/null) \
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

# set_ask <repo> <issue> <channel> <ts> <asked_at> <status> <reminded> — replace/insert the record
set_ask() {
  { [ -f "$ASKS" ] && awk -F'\t' -v r="$1" -v i="$2" '!($1==r && $2==i)' "$ASKS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; } | write_atomic "$ASKS"
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

cmd_ask() {
  [ $# -ge 3 ] || die "usage: pm-slack.sh ask <owner/repo> <issue> <text>"
  local repo=$1 issue=$2 text=$3 short=${1##*/} now cur status reminded asked_at ch msg
  case "$issue" in ''|*[!0-9]*) die "issue must be a number" ;; esac
  lock 60 || die "another pm-slack run holds the lock"
  now=$(date +%s)
  cur=$([ -f "$ASKS" ] && awk -F'\t' -v r="$repo" -v i="$issue" '$1==r && $2==i' "$ASKS")
  if [ -n "$cur" ]; then
    IFS="$TAB" read -r _ _ _ _ asked_at status reminded <<< "$cur"
    if [ "$status" = open ]; then
      # one open ask per issue; exactly one reminder after 24h, then never again for this ask
      [ "$reminded" = 0 ] && [ $((now - asked_at)) -ge "$REMIND_AFTER_SECS" ] || exit 0
      ch=$(open_dm) || exit 1
      msg="#$issue · $short"$'\n'"Reminder: still waiting on your answer to the message above."$'\n\n'"Reply here with #$issue and your answer."
      post "$ch" "$msg" || exit 1
      IFS="$TAB" read -r _ _ _ ts _ <<< "$cur"
      set_ask "$repo" "$issue" "$ch" "$ts" "$asked_at" open 1
      exit 0
    fi
  fi
  ch=$(open_dm) || exit 1
  msg="#$issue · $short"$'\n'"$text"$'\n\n'"Reply here with #$issue and your answer."
  post "$ch" "$msg" || exit 1
  [ -n "$POSTED_TS" ] || die "chat.postMessage returned no ts"
  set_ask "$repo" "$issue" "$ch" "$POSTED_TS" "$now" open 0
  [ -f "$LASTREAD" ] || printf '%s\n' "$POSTED_TS" | write_atomic "$LASTREAD"   # replies are read from the first ask on
  gh issue comment "$issue" --repo "$repo" --body "**[project-manager] NOTE** slack-ask: $POSTED_TS" >/dev/null \
    || die "ask posted (ts $POSTED_TS) but the slack-ask comment on $repo#$issue failed"
}

unslack() { printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'; }   # Slack HTML-escapes & < >

cmd_poll() {
  lock 0 || exit 0                       # an overlapping poll is already running
  [ -f "$LASTREAD" ] || exit 0           # no ask ever made on this host
  local last ch msgs mts mtext m tokens tok matches n repo issue mch pend
  last=$(cat "$LASTREAD")
  ch=$(cat "$CHANNEL_FILE" 2>/dev/null); [ -n "$ch" ] || ch=$(open_dm) || exit 1
  slack conversations.history "$(jq -nc --arg c "$ch" --arg o "$last" '{channel:$c,oldest:$o,limit:200}')" || exit 1
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
        IFS="$TAB" read -r repo issue mch _ _ _ _ <<< "$matches"
        gh issue comment "$issue" --repo "$repo" --body "**[project-manager] NOTE** jp-reply (slack): $mtext" >/dev/null \
          || { echo "pm-slack: comment on $repo#$issue failed" >&2; exit 1; }
        IFS="$TAB" read -r _ _ _ ats aat _ rem <<< "$matches"
        set_ask "$repo" "$issue" "$mch" "$ats" "$aat" answered "$rem"
        slack reactions.add "$(jq -nc --arg c "$ch" --arg t "$mts" '{channel:$c,timestamp:$t,name:"white_check_mark"}')" \
          || echo "pm-slack: reaction failed (reply was recorded)" >&2
      else
        post "$ch" "Which issue is this about? Start your reply with #<issue> — pending: $(printf '%s\n' "$pend" | awk -F'\t' '{printf "#%s (%s) ", $2, $1}' | sed 's#[^ ]*/##g')" \
          || exit 1
      fi
    fi
    printf '%s\n' "$mts" | write_atomic "$LASTREAD"
  done 3<<< "$msgs"   # own fd: curl/gh must not eat the loop's input
}

case "${1:-}" in
  ask)  shift; cmd_ask "$@" ;;
  poll) cmd_poll ;;
  *)    die "usage: pm-slack.sh ask <owner/repo> <issue> <text> | poll" ;;
esac
