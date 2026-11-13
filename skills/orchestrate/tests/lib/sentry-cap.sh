# Shared fixture for the #182 tests (daily launch cap on sentry-auto-go tickets): test-issue182-sentry-cap.sh and
# test-issue182-sentry-cap-supervisor.sh source it. Isolated HOME/PIPE, two dispatched placeholder repos, stubbed
# `gh`, `claude`, `pmset`, `curl`. Placeholder repo names only (this repo is public).
#
# Stub gh keeps issues in $SC_D/issues.json ([{number,repo,labels:[{name}]}]) and every comment in $SC_D/comments.json,
# applies --label / --jq like the real CLI, honours `issue edit --add-label/--remove-label`, answers `repo view` from the
# named repo or the checkout's origin, and logs every call to $SC_D/gh-calls.log. orchestrate.sh's label read
# (`api repos/<owner/repo>/issues/<n> --jq ...`) is answered from issues.json; $SC_D/labels-fail makes it exit 1 (with a
# token-shaped string on stderr that must never be logged). With $SC_D/rest-comments the supervisor's REST comment reads
# (`api repos/<owner/repo>/issues/<n>/comments...`) are answered from comments.json (the queue drain arbitrates its claim
# there). Every other `api` call exits 0 with no output.
# Stub claude logs its argv to $SC_D/claude.log; with $SC_D/claude-hold it then stays alive (a running orchestrator).
# Stub curl logs its argv to $SC_D/curl.log (the Slack webhook alert).

HERE_SCL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_SC="$HERE_SCL/../.."
ROOT_SC="$RS_SC/../.."
SUP_SC="$RS_SC/supervisor.sh"
ORCH_SC="$RS_SC/orchestrate.sh"
SC_A="project-a/repo-a"
SC_B="project-b/repo-b"

# sc_env [config.local.sh line...] — sets SC_PIPE, SC_HOME, SC_D, SC_RA, SC_RB, SC_LOG (the launch log path)
sc_env() {
  SC_PIPE=$(new_pipe); SC_HOME=$(new_home); SC_D="$SC_HOME/.local/bin"; mkdir -p "$SC_D"
  SC_RA="$SC_PIPE/repo-a"; SC_RB="$SC_PIPE/repo-b"; SC_LOG="$SC_PIPE/sentry-launches.log"
  SC_WEBHOOK=""; SC_BYPASS=""; SC_LABELLED=""
  fixture_repo "$SC_RA" "$SC_A"; fixture_repo "$SC_RB" "$SC_B"
  echo '[]' > "$SC_D/issues.json"; echo '[]' > "$SC_D/comments.json"
  : > "$SC_D/gh-calls.log"; : > "$SC_D/claude.log"; : > "$SC_D/curl.log"
  { echo 'MEM_FLOOR_MB=0'; echo 'CLAIM_SETTLE_SECS=0'
    printf 'DISPATCH_REPOS=("%s:%s" "%s:%s")\n' "$SC_A" "$SC_RA" "$SC_B" "$SC_RB"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$SC_HOME/.claude/pipeline/config.local.sh"
  cat > "$SC_D/pmset" <<'X'
#!/bin/bash
echo "Now drawing from 'AC Power'"
X
  cat > "$SC_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/claude.log"
[ -f "$D/claude-hold" ] && exec /bin/sleep 30
exit 0
X
  cat > "$SC_D/curl" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$D/curl.log"
exit 0
X
  cat > "$SC_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/gh-calls.log"
jqx=""; label=""; repo=""; prev=""; addl=""; reml=""; body=""
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a;; --label) label=$a;; --repo) repo=$a;; --add-label) addl=$a;; --remove-label) reml="$reml,$a";; --body) body=$a;; esac; prev=$a
done
out() { if [ -n "$jqx" ]; then printf '%s' "$1" | jq -r "$jqx"; else printf '%s\n' "$1"; fi; }
here_repo() { git config --get remote.origin.url 2>/dev/null | sed -E 's#.*github.com/(.*)\.git#\1#'; }
num=$(printf '%s' "${3:-}" | grep -E '^[0-9]+$')
case "${1:-} ${2:-}" in
  "api repos/"*"/issues/"[0-9]*)
    case "$2" in */comments*)
      # opt-in: the comment list in REST shape; a POST (-f body=...) is recorded like `issue comment`
      [ -f "$D/rest-comments" ] || exit 0
      case "$*" in *" -f body="*)
        b=$(printf '%s' "$*" | sed 's/^.* -f body=//')
        jq --arg b "$b" --arg t "$(date -u +%FT%TZ)" '. + [{body:$b,createdAt:$t}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"; exit 0;;
      esac
      jq -c 'map({body: .body, created_at: .createdAt})' "$D/comments.json"; exit 0;;
    esac
    [ -n "$jqx" ] || exit 0   # only the launcher's label read carries --jq; the supervisor's own issue reads stay empty
    [ -f "$D/labels-fail" ] && { echo "HTTP 401: Bad credentials token=ghp_SECRETSECRETSECRET" >&2; exit 1; }
    out "$(jq -c --argjson n "${2##*/}" '{state:"open",title:"Customer Jane Doe cannot save",labels:[.[] | select(.number==$n) | .labels[]]}' "$D/issues.json")"; exit 0;;
  "repo view")
    r=$repo; [ -n "$r" ] || case "${3:-}" in */*) r=$3;; esac; [ -n "$r" ] || r=$(here_repo)
    out "{\"nameWithOwner\":\"$r\"}"; exit 0;;
  "issue list")
    r=${repo:-$(here_repo)}
    out "$(jq -c --arg r "$r" --arg l "$label" '[.[] | select(.repo==$r) | select($l=="" or ([.labels[].name]|index($l)))]' "$D/issues.json")"; exit 0;;
  "issue comment")
    jq --arg b "$body" --arg t "$(date -u +%FT%TZ)" '. + [{body:$b,createdAt:$t}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"; exit 0;;
  "issue edit")
    jq --argjson n "${num:-0}" --arg a "$addl" --arg r "$reml" '
      map(if .number==$n then .labels = ((.labels|map(.name)) - ($r|split(",")) + ($a|split(",")|map(select(.!=""))) | unique | map({name:.})) else . end)' \
      "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"; exit 0;;
  "issue view")
    out "$(jq -c --argjson n "${num:-0}" --slurpfile c "$D/comments.json" \
      '{state:"OPEN",title:"Customer Jane Doe cannot save",labels:[.[] | select(.number==$n) | .labels[]],comments:$c[0]}' "$D/issues.json")"; exit 0;;
esac
exit 0
X
  chmod +x "$SC_D/pmset" "$SC_D/claude" "$SC_D/curl" "$SC_D/gh"
}

# sc_issue <num> <owner/repo> <label>...
sc_issue() {
  local n=$1 r=$2; shift 2
  jq --argjson n "$n" --arg r "$r" --argjson l "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({name:.})')" \
    '. + [{number:$n,repo:$r,labels:$l}]' "$SC_D/issues.json" > "$SC_D/i.tmp" && mv "$SC_D/i.tmp" "$SC_D/issues.json"
}
sc_labels() { jq -r --argjson n "$1" '.[]|select(.number==$n)|[.labels[].name]|sort|join(",")' "$SC_D/issues.json"; }

# sc_seed <owner/repo> <secs-ago>... — one launch-log line per age, issue numbers 900, 901, ...
sc_seed() {
  local r=$1 now i=900 a; shift; now=$(date +%s)
  for a in "$@"; do printf '%s %s %s\n' "$((now - a))" "$r" "$i" >> "$SC_LOG"; i=$((i + 1)); done
}
sc_log_lines() { if [ -f "$SC_LOG" ]; then wc -l < "$SC_LOG" | tr -d ' '; else echo 0; fi; }

sc_path() { printf '%s' "$SC_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"; }
# The stub orchestrator is started detached (nohup ... &), so its claude.log line can land after the launcher returned.
# Nothing here sleeps a fixed time: every launch the launcher reported is waited for, bounded.
# sc_wait_launches <n> — up to 5 s until claude.log holds at least <n> orchestrator launches
sc_wait_launches() {
  local i=0
  while [ "$(sc_orch_launches)" -lt "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  return 0
}
# sc_tick — one supervisor tick; waits for every launch its log reports (step 5: "claimed by <host> ... orchestrate.sh status
# <ticket>", the last line of a successful launch; queue drain: "[launch] #<n> pid=")
sc_tick() {
  HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" SLACK_WEBHOOK_URL="$SC_WEBHOOK" SENTRY_CAP_BYPASS="" SENTRY_CAP_LABELLED="" \
    /bin/bash "$SUP_SC" >/dev/null 2>&1
  sc_wait_launches "$(sc_suplog | grep -cE 'claimed by .*orchestrate\.sh status |\[launch\] #[0-9]+ pid=')"
}
# sc_launch <checkout> <issue> [orchestrate.sh flags...] — a hand launch; prints stdout+stderr, returns the exit code.
# SC_BYPASS / SC_LABELLED / SC_WEBHOOK feed SENTRY_CAP_BYPASS / SENTRY_CAP_LABELLED / SLACK_WEBHOOK_URL.
sc_launch() {
  local repo=$1 n=$2 rc out before; shift 2
  before=$(sc_orch_launches)
  out=$(HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" \
    SLACK_WEBHOOK_URL="$SC_WEBHOOK" SENTRY_CAP_BYPASS="$SC_BYPASS" SENTRY_CAP_LABELLED="$SC_LABELLED" \
    /bin/bash "$ORCH_SC" "$@" "$repo" "$n" 2>&1); rc=$?
  printf '%s\n' "$out"
  case "$out" in *"launched orchestrator for"*) sc_wait_launches $((before + 1)) ;; esac
  return $rc
}
# sc_lib <shell code> — runs it with config.sh + pipeline-lib.sh sourced in the fixture environment
sc_lib() {
  ( export HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" SLACK_WEBHOOK_URL="$SC_WEBHOOK"
    . "$RS_SC/config.sh"; . "$RS_SC/pipeline-lib.sh"; eval "$1" )
}
# sc_label_reads <owner/repo> <issue> — how many times the launcher read that issue's labels
sc_label_reads() { grep -c "^api repos/$1/issues/$2 --jq" "$SC_D/gh-calls.log"; }
sc_orch_launches() { grep -c -- '--agent orchestrator' "$SC_D/claude.log"; }
sc_suplog() { cat "$SC_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
sc_cleanup() {
  local f pid
  if [ -f "$SC_D/claude-hold" ]; then   # only then is a recorded pid a live stub orchestrator
    for f in "$SC_PIPE"/orch-*.pid; do
      [ -e "$f" ] || continue
      pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
    done
  fi
  cleanup_running; rm -rf "$SC_PIPE" "$SC_HOME"
}
