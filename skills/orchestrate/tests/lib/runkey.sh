# Helpers for the #213 (run state keyed by repo + number) tests. Sourced by test-issue213-*.sh.
# Deliberately independent of fixture.sh's mk_* helpers (those are number-keyed and change under #213):
# every run file here is created under a HAND-WRITTEN name, never by calling run_key.
#
# Two placeholder repos share every issue number used in these tests:
#   RK_A = project-a/repo-1   files   orch-project-a_repo-1-<N>.*   queue/orch-project-a_repo-1-<N>.json
#   RK_B = project-b/repo-2   files   orch-project-b_repo-2-<N>.*   queue/orch-project-b_repo-2-<N>.json
# (hyphens and digits in the names exercise "N = text after the last '-'").
# Placeholder names only (public repo). Bash 3.2 portable.

RK_PIDS=""
RK_KA="orch-project-a_repo-1"
RK_KB="orch-project-b_repo-2"
RK_OWNER_A="project-a/repo-1"
RK_OWNER_B="project-b/repo-2"

# rk_env — isolated PIPE/HOME + two git checkouts + a per-repo fake gh + stub claude/pmset.
rk_env() {
  RK_PIPE=$(new_pipe); RK_HOME=$(new_home)
  RK_BIN="$RK_HOME/.local/bin"; mkdir -p "$RK_BIN"
  RK_REPO_A="$RK_PIPE/checkout-a"; RK_REPO_B="$RK_PIPE/checkout-b"
  fixture_repo "$RK_REPO_A" "$RK_OWNER_A"
  fixture_repo "$RK_REPO_B" "$RK_OWNER_B"
  ( cd "$RK_REPO_A" && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
  RK_DATA="$RK_BIN/data"; mkdir -p "$RK_DATA"
  : > "$RK_BIN/calls.log"
  cat > "$RK_BIN/gh" <<'GH_EOF'
#!/bin/bash
# per-repo fake gh: the repo comes from --repo, else from the cwd checkout's origin url.
D=$(cd "$(dirname "$0")" && pwd)
repo=""; prev=""; jqexpr=""
for a in "$@"; do
  [ "$prev" = "--repo" ] && repo=$a
  [ "$prev" = "--jq" ] && jqexpr=$a
  prev=$a
done
if [ -z "$repo" ]; then
  url=$(git config --get remote.origin.url 2>/dev/null); url=${url%.git}; repo=${url#https://github.com/}
fi
key=$(printf '%s' "$repo" | tr '/' '_')
printf '%s | %s\n' "$repo" "$*" >> "$D/calls.log"
rd() { cat "$D/data/$key/$1" 2>/dev/null; }
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
case "$1 $2" in
  "repo view") [ -f "$D/repo-view-fail" ] && exit 1; emit "{\"nameWithOwner\":\"$repo\"}" ;;
  "issue view")
    n=$3
    title=$(rd "title-$n"); [ -n "$title" ] || title="title of $repo#$n"
    state=$(rd "state-$n"); [ -n "$state" ] || state=OPEN
    ms=$(rd "milestone-$n"); closed=$(rd "closed-at-$n")
    comments=$(rd "comments-$n"); [ -n "$comments" ] || comments="[]"
    json=$(jq -n --arg t "$title" --arg s "$state" --arg m "$ms" --arg c "$closed" --argjson cm "$comments" \
      '{title:$t, state:$s, labels:[], closedAt:(if $c=="" then null else $c end), comments:$cm,
        milestone:(if $m=="" then null else {title:$m} end)}')
    emit "$json" ;;
  "issue list")
    case "$*" in
      *"--label agent-go"*) l=$(rd list-go); [ -n "$l" ] || l="[]"; emit "$l" ;;
      *) emit "[]" ;;
    esac ;;
  "issue comment")
    n=$3; body=""; p=""
    for a in "$@"; do [ "$p" = "--body" ] && body=$a; p=$a; done
    mkdir -p "$D/data/$key"
    cur=$(rd "comments-$n"); [ -n "$cur" ] || cur="[]"
    printf '%s' "$cur" | jq --arg b "$body" --arg t "$(date -u +%FT%TZ)" '. + [{body:$b, createdAt:$t}]' > "$D/data/$key/comments-$n"
    exit 0 ;;
  "issue edit") exit 0 ;;
  *) echo "rk fake gh: unexpected: $*" >&2; exit 1 ;;
esac
GH_EOF
  chmod +x "$RK_BIN/gh"
  printf '#!/bin/bash\nexec sleep 30\n' > "$RK_BIN/claude"; chmod +x "$RK_BIN/claude"
  # curl stub: records every call (args incl. -d payload) and answers like Slack's chat.postMessage ok
  cat > "$RK_BIN/curl" <<'CURL_EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/curl.log"
echo '{"ok":true}'
CURL_EOF
  chmod +x "$RK_BIN/curl"
  for t in crontab vercel; do printf '#!/bin/bash\nexit 0\n' > "$RK_BIN/$t"; chmod +x "$RK_BIN/$t"; done
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$RK_BIN/pmset"; chmod +x "$RK_BIN/pmset"
  cat > "$RK_HOME/.claude/pipeline/config.local.sh" <<CFG
MEM_FLOOR_MB=0
CLAIM_SETTLE_SECS=0
DISPATCH_REPOS=("$RK_OWNER_A:$RK_REPO_A" "$RK_OWNER_B:$RK_REPO_B")
STATUS_REPO_ALIASES=("$RK_OWNER_A:alias-a" "$RK_OWNER_B:alias-b")
CFG
}

# rk_gh_set <A|B> <field-with-number> <value>   e.g. rk_gh_set A title-196 "Title A"
rk_gh_set() {
  local who=$1 f=$2 v=$3 k
  [ "$who" = A ] && k=project-a_repo-1 || k=project-b_repo-2
  mkdir -p "$RK_DATA/$k"; printf '%s' "$v" > "$RK_DATA/$k/$f"
}

rk_cleanup() {
  local f p
  for f in "$RK_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    p=$(cat "$f" 2>/dev/null)
    [ -n "$p" ] && { pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; }
  done
  for p in $RK_PIDS; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  RK_PIDS=""
  rm -rf "$RK_PIPE" "$RK_HOME"
  return 0
}

# rk_live — prints the pid of a live, double-forked sleep (reparented, so never a zombie of this shell).
rk_live() {
  local p
  p=$( ( sleep 300 >/dev/null 2>&1 & echo $! ) )
  RK_PIDS="$RK_PIDS $p"
  printf '%s' "$p"
}

rk_dead_pid() {  # a pid with no live process
  local p=99999
  while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done
  printf '%s' "$p"
}

# rk_alive <pid> — 0 when the process exists and is not a zombie
rk_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*|"") return 1 ;; esac
  return 0
}

# rk_run_files <key> <checkout> <live|held|done|stopped|restarting> [<N>]  — hand-writes one run's files.
# Prints the pid (live) or nothing.
rk_run_files() {
  local key=$1 repo=$2 state=$3 n=$4 pid
  if [ "$state" = live ]; then pid=$(rk_live); else pid=$(rk_dead_pid); fi
  echo "$pid" > "$RK_PIPE/$key-$n.pid"
  echo "$repo" > "$RK_PIPE/$key-$n.repo"
  date -u +%FT%TZ > "$RK_PIPE/$key-$n.start"
  : > "$RK_PIPE/$key-$n.log"
  case "$state" in
    held) touch "$RK_PIPE/$key-$n.held" ;;
    done) touch "$RK_PIPE/$key-$n.done" ;;
    stopped) touch "$RK_PIPE/$key-$n.stopped" ;;
  esac
  [ "$state" = live ] && printf '%s' "$pid"
  return 0
}

# rk_queue_entry <key> <checkout> <N> [queued_at]  — queue/<key>-<N>.json
rk_queue_entry() {
  local key=$1 repo=$2 n=$3 qa=${4:-}
  python3 -c "
import json, sys, datetime
key, repo, n, qa = sys.argv[1:5]
if not qa: qa = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'issue': n, 'repo': repo, 'extra': '', 'reason': 'queued', 'queued_at': qa, 'not_before': 0},
          open('$RK_PIPE/queue/' + key + '-' + n + '.json', 'w'))
" "$key" "$repo" "$n" "$qa"
}

rk_env_run() {  # rk_env_run <script> [args...] — runs it in the isolated env; output on stdout
  HOME="$RK_HOME" PATH="$RK_BIN:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$@" 2>&1
}

rk_sum() {  # rk_sum <file> -> cksum of content, or ABSENT
  if [ -e "$1" ]; then cksum < "$1"; else echo ABSENT; fi
}

rk_wait_dead() {  # rk_wait_dead <pid> — up to ~3 s for the process to be gone
  local i=0
  while rk_alive "$1" && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  rk_alive "$1" && return 1
  return 0
}
