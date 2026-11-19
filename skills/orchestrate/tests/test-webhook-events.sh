# #773 — GitHub webhook receiver (webhook-receiver.py), event queue read path (webhook-events.sh), the gh_since_sync choke point
# (gh-budget.sh), the kill switch (config.sh) and the stale-feed beat field (report-status.sh). Real receiver process on 127.0.0.1:<random>,
# stub gh / fake Slack server; no GitHub, no network beyond loopback. Prefix wh_ / WH_. Placeholder repo names only; the secrets below are
# fixtures, not credentials.
#
#   AC1  wh_ac1_*   missing / malformed / sha1 / wrong signature -> 401, nothing queued
#   AC2  wh_ac2_*   a replayed X-GitHub-Delivery is queued once, also across a receiver restart
#   AC3  wh_ac3_*   body cap 413, rate limit 429, method/path allow-list, /events bearer auth
#   AC4  wh_ac4_*   shell metacharacters in a payload create nothing; static grep: no eval / shell=True / unquoted payload use
#   AC5  wh_ac5_*   sequence, /events?since=, the Mac pull (cursor, bad token, reset queue)
#   AC6  wh_ac6_*   supervisor read path: only touched objects re-read, fallback poll heals a dropped event
#   AC7  wh_ac7_*   VM receiver last-event beat field (#782) + status-page text lives in status-page/test/webhook-stale.test.js
#   AC9  wh_ac9_*   kill switch default 0, off = no API-call or state difference
#   AC12 wh_ac12_*  a receiver error and a pull error are captured with release / environment / route tags and no secrets

WH_RS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WH_SECRET="fixture-secret-aaaaaaaaaaaaaaaaaaaa"
WH_TOKEN="fixture-token-bbbbbbbbbbbbbbbbbbbbbb"
WH_PIDS=""

wh_cleanup() { local p; for p in $WH_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; WH_PIDS=""; }

wh_wait_line() {  # <file> -> prints the first line once it exists (up to ~8 s)
  local i=0 l
  while [ "$i" -lt 80 ]; do l=$(head -n 1 "$1" 2>/dev/null); [ -n "$l" ] && { printf '%s' "$l"; return 0; }; sleep 0.1; i=$((i + 1)); done
  return 1
}

# wh_start <state dir> [VAR=value ...] — starts the receiver on a random port; sets WH_PORT, WH_PID, WH_ERR
wh_start() {
  local state=$1; shift
  WH_ERR="$state.err"; : > "$WH_ERR"; rm -f "$state.out"
  env WEBHOOK_SECRET="$WH_SECRET" WEBHOOK_PULL_TOKEN="$WH_TOKEN" WEBHOOK_STATE_DIR="$state" WEBHOOK_PORT=0 "$@" \
    python3 "$WH_RS/webhook-receiver.py" > "$state.out" 2> "$WH_ERR" &
  WH_PID=$!; WH_PIDS="$WH_PIDS $WH_PID"
  local line; line=$(wh_wait_line "$state.out") || return 1
  WH_PORT=${line##*:}
}
wh_stop() { kill "$WH_PID" 2>/dev/null; wait "$WH_PID" 2>/dev/null; }

wh_sig() { printf 'sha256=%s' "$(openssl dgst -sha256 -hmac "$WH_SECRET" < "$1" | awk '{print $NF}')"; }
wh_body() {  # <file> <issue number> <title> [event shape: issues|org]
  if [ "${4:-issues}" = org ]; then
    jq -nc '{action:"created",organization:{login:"example-owner"},sender:{login:"octo-user"}}' > "$1"
  else
    jq -nc --argjson n "$2" --arg t "$3" '{action:"opened",issue:{number:$n,title:$t,body:"private text"},repository:{full_name:"example-owner/project-a",owner:{login:"example-owner"}},organization:{login:"example-owner"},sender:{login:"octo-user"}}' > "$1"
  fi
}
# wh_post <body file> <delivery id> <event> [signature header value | -] -> http code; response in $WH_RESP
wh_post() {
  local f=$1 d=$2 ev=$3 sig=${4:-}
  [ -n "$sig" ] || sig=$(wh_sig "$f")
  local args=(-s -o "$WH_RESP" -w '%{http_code}' -X POST --data-binary "@$f" -H "X-GitHub-Event: $ev" -H "X-GitHub-Delivery: $d" -H 'Content-Type: application/json')
  [ "$sig" = "-" ] || args+=(-H "X-Hub-Signature-256: $sig")
  curl "${args[@]}" "http://127.0.0.1:$WH_PORT/webhook"
}
wh_qlines() { local n; n=$(grep -c . "$1/events.jsonl" 2>/dev/null); echo "${n:-0}"; }
wh_get() { curl -s -o "$WH_RESP" -w '%{http_code}' "$@"; }   # <curl args>

wh_setup() {
  WH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-wh.XXXXXX"); WH_STATE="$WH_DIR/state"; WH_RESP="$WH_DIR/resp"
}
wh_teardown() { wh_cleanup; rm -rf "$WH_DIR"; }

# ---- AC1 ------------------------------------------------------------------------------------------------------------------------
test_wh_ac1_bad_signatures_are_401_and_queue_nothing() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local good codes
  good=$(wh_sig "$WH_DIR/b.json")
  local flipped="${good%?}"; case "${good: -1}" in 0) flipped="${flipped}1" ;; *) flipped="${flipped}0" ;; esac
  codes="$(wh_post "$WH_DIR/b.json" d-0000001 issues "$flipped") $(wh_post "$WH_DIR/b.json" d-0000002 issues -) $(wh_post "$WH_DIR/b.json" d-0000003 issues "sha1=${good#sha256=}") $(wh_post "$WH_DIR/b.json" d-0000004 issues "sha256=nothex") $(wh_post "$WH_DIR/b.json" d-0000005 issues "")"
  local n; n=$(wh_qlines "$WH_STATE")
  wh_teardown
  # the last call re-signs (empty override = valid) so it is the one 202
  assert_eq "$codes" "401 401 401 401 202" "AC1: flipped digit, missing, sha1=, non-hex are 401 (a valid signature still works)" || return 1
  assert_eq "$n" "1" "AC1: only the validly signed delivery is queued" || return 1
}

test_wh_ac1_valid_signed_issue_is_202_and_stores_tags_only() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "Secret title"
  local code line; code=$(wh_post "$WH_DIR/b.json" d-1111111 issues)
  line=$(head -n 1 "$WH_STATE/events.jsonl"); wh_stop
  local got; got=$(printf '%s' "$line" | jq -c '[.seq,.event,.action,.repo,.number,.sender,.delivery]' 2>/dev/null)
  wh_teardown
  assert_eq "$code" "202" "AC1: valid signed issues payload" || return 1
  assert_eq "$got" '[1,"issues","opened","example-owner/project-a",7,"octo-user","d-1111111"]' "AC1: queued tags" || return 1
  assert_not_contains "$line" "Secret title" "AC1: the queue never stores payload text" || return 1
  assert_not_contains "$line" "private text" "AC1: the queue never stores the body" || return 1
}

test_wh_ac1_ping_and_unlisted_events_are_not_queued() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local c1 c2 c3 n
  c1=$(wh_post "$WH_DIR/b.json" d-2222221 ping); c2=$(wh_post "$WH_DIR/b.json" d-2222222 push)
  wh_body "$WH_DIR/o.json" 0 "" org; c3=$(wh_post "$WH_DIR/o.json" d-2222223 projects_v2_item)
  local org; org=$(jq -c '[.repo,.owner,.number]' "$WH_STATE/events.jsonl" 2>/dev/null); n=$(wh_qlines "$WH_STATE")
  wh_teardown
  assert_eq "$c1 $c2 $c3" "200 200 202" "AC1: ping and an unlisted event are accepted but not queued; projects_v2_item is queued" || return 1
  assert_eq "$n" "1" "AC1: one queued line" || return 1
  assert_eq "$org" '[null,"example-owner",null]' "AC1: an org-level event carries no repo" || return 1
}

# ---- AC2 ------------------------------------------------------------------------------------------------------------------------
test_wh_ac2_replayed_delivery_is_queued_once_across_restart() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local c1 c2 c3 c4 seq2
  c1=$(wh_post "$WH_DIR/b.json" d-3333331 issues); c2=$(wh_post "$WH_DIR/b.json" d-3333331 issues)
  wh_stop; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not restart"; return 1; }
  c3=$(wh_post "$WH_DIR/b.json" d-3333331 issues)
  c4=$(wh_post "$WH_DIR/b.json" d-3333332 issues); seq2=$(jq -r '.seq' "$WH_RESP")
  local n; n=$(wh_qlines "$WH_STATE")
  wh_teardown
  assert_eq "$c1 $c2 $c3 $c4" "202 200 200 202" "AC2: replays are 2xx" || return 1
  assert_eq "$n" "2" "AC2: the replayed id was queued once (two distinct ids, two lines)" || return 1
  assert_eq "$seq2" "2" "AC2: the sequence continues after a restart" || return 1
}

# ---- AC3 ------------------------------------------------------------------------------------------------------------------------
test_wh_ac3_oversize_body_is_413() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  head -c 1048577 /dev/zero | tr '\0' 'a' > "$WH_DIR/big.json"
  local over ok; over=$(wh_post "$WH_DIR/big.json" d-4444441 issues)
  head -c 1048576 /dev/zero | tr '\0' 'a' > "$WH_DIR/edge.json"; ok=$(wh_post "$WH_DIR/edge.json" d-4444442 issues)   # at the cap: passes the size check, fails JSON
  local n; n=$(wh_qlines "$WH_STATE"); wh_teardown
  assert_eq "$over" "413" "AC3: 1 MiB + 1 byte with a valid signature" || return 1
  assert_eq "$ok" "400" "AC3: exactly 1 MiB is not a size error" || return 1
  assert_eq "$n" "0" "AC3: nothing queued" || return 1
}

test_wh_ac3_rate_limit_121st_request_is_429() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  local args=() i=0; while [ "$i" -lt 121 ]; do args+=(-o /dev/null "http://127.0.0.1:$WH_PORT/health"); i=$((i + 1)); done   # -o per URL: curl applies each option to one URL only
  local codes; codes=$(curl -s -w '%{http_code}\n' "${args[@]}" | sort | uniq -c | tr -s ' ' | tr '\n' ';')
  wh_teardown
  assert_eq "$codes" " 120 200; 1 429;" "AC3: 120 ok then 429 on the 121st" || return 1
}

test_wh_ac3_method_and_path_allow_list() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  local b="http://127.0.0.1:$WH_PORT" r
  r="$(wh_get "$b/nope") $(wh_get "$b/webhook") $(wh_get -X POST "$b/events") $(wh_get -X PUT "$b/health") $(wh_get -X DELETE "$b/webhook") $(wh_get -X POST "$b/webhook") $(wh_get "$b/health")"
  wh_teardown
  assert_eq "$r" "404 405 405 405 405 411 200" "AC3: unknown path 404, wrong method 405, POST without Content-Length 411, /health 200" || return 1
}

test_wh_ac3_events_requires_the_bearer_token() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  local b="http://127.0.0.1:$WH_PORT" r
  r="$(wh_get "$b/events") $(wh_get -H 'Authorization: Bearer wrong-token-wrong-token' "$b/events") $(wh_get -H "Authorization: Basic $WH_TOKEN" "$b/events") $(wh_get -H "Authorization: Bearer $WH_TOKEN" "$b/events") $(wh_get -H "Authorization: Bearer $WH_TOKEN" "$b/events?since=abc")"
  wh_teardown
  assert_eq "$r" "401 401 401 200 400" "AC3: missing, wrong, non-bearer token 401; right token 200; bad since 400" || return 1
}

test_wh_ac3_refuses_to_start_without_both_secrets() {
  wh_setup
  local rc1 rc2 rc3
  env WEBHOOK_SECRET="" WEBHOOK_PULL_TOKEN="$WH_TOKEN" WEBHOOK_STATE_DIR="$WH_STATE" WEBHOOK_PORT=0 python3 "$WH_RS/webhook-receiver.py" >/dev/null 2>&1; rc1=$?
  env WEBHOOK_SECRET="$WH_SECRET" WEBHOOK_PULL_TOKEN="short" WEBHOOK_STATE_DIR="$WH_STATE" WEBHOOK_PORT=0 python3 "$WH_RS/webhook-receiver.py" >/dev/null 2>&1; rc2=$?
  env WEBHOOK_SECRET="$WH_SECRET" WEBHOOK_PULL_TOKEN="$WH_SECRET" WEBHOOK_STATE_DIR="$WH_STATE" WEBHOOK_PORT=0 python3 "$WH_RS/webhook-receiver.py" >/dev/null 2>&1; rc3=$?
  wh_teardown
  assert_eq "$rc1 $rc2 $rc3" "2 2 2" "AC3: empty secret, short token, identical values all refuse to start" || return 1
}

# ---- AC4 ------------------------------------------------------------------------------------------------------------------------
test_wh_ac4_shell_metacharacters_in_a_payload_create_nothing() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "\$(touch $WH_DIR/pwned); \`touch $WH_DIR/pwned2\`; touch $WH_DIR/pwned3"
  local code; code=$(wh_post "$WH_DIR/b.json" d-5555551 issues)
  wh_stop
  local valid; valid=$(jq -e . "$WH_STATE/events.jsonl" >/dev/null 2>&1 && echo yes || echo no)
  # the consumer read path as well: apply the queue through webhook-events.sh
  local pipe="$WH_DIR/pipe"; mkdir -p "$pipe"; cp -r "$WH_STATE" "$pipe/webhook"
  PIPE="$pipe" WEBHOOK_EVENTS_ENABLED=1 bash -c ". '$WH_RS/webhook-events.sh'; webhook_events_since 0 >/dev/null; webhook_tick_prepare" >/dev/null 2>&1
  local made; made=$(ls "$WH_DIR" | grep -c '^pwned' | tr -d ' ')
  wh_teardown
  assert_eq "$code" "202" "AC4: the hostile payload is a normal delivery" || return 1
  assert_eq "$valid" "yes" "AC4: the queue line is valid JSON" || return 1
  assert_eq "$made" "0" "AC4: no file was created by the producer or the consumer" || return 1
}

test_wh_ac4_no_eval_or_shell_execution_in_receiver_and_consumers() {
  local f hits=""
  hits=$(
    grep -nE 'os\.system|shell=True|\beval\(|\bexec\(|os\.popen|subprocess\.(call|run|Popen|check_output)' "$WH_RS/webhook-receiver.py" | grep -v 'git", "-C"'
    for f in webhook-receiver.sh webhook-events.sh; do
      grep -v '^[[:space:]]*#' "$WH_RS/$f" | grep -nE '(^|[^A-Za-z_])eval[[:space:]]'
    done
  )
  assert_eq "$hits" "" "AC4: no eval / os.system / shell=True / arbitrary subprocess in the receiver or its consumers" || return 1
  # the only subprocess call is the argv-list git rev-parse for the release tag
  assert_contains "$(grep -c 'subprocess.run(\["git", "-C"' "$WH_RS/webhook-receiver.py")" "1" "AC4: the one subprocess call is an argv list" || return 1
}

# ---- AC5 ------------------------------------------------------------------------------------------------------------------------
test_wh_ac5_events_since_returns_only_newer_events_in_order() {
  wh_setup; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local i=1; while [ "$i" -le 3 ]; do wh_post "$WH_DIR/b.json" "d-666666$i" issues >/dev/null; i=$((i + 1)); done
  wh_get -H "Authorization: Bearer $WH_TOKEN" "http://127.0.0.1:$WH_PORT/events?since=1" >/dev/null
  local got; got=$(jq -c '[.latest,.oldest,[.events[].seq]]' "$WH_RESP")
  wh_teardown
  assert_eq "$got" "[3,1,[2,3]]" "AC5: since=1 -> seqs 2,3 with latest 3 / oldest 1" || return 1
}

# we_pull_env <pipe> <port> [token] — one `webhook_pull` in a fresh bash, the way a Mac supervisor tick calls it
we_pull() {
  local pipe=$1 port=$2 tok=${3:-$WH_TOKEN}
  PIPE="$pipe" HOME="$WH_DIR/home" WEBHOOK_EVENTS_ENABLED=1 WEBHOOK_RECEIVER_URL="http://127.0.0.1:$port" WEBHOOK_PULL_TOKEN="$tok" \
    SLACK_WEBHOOK_URL="${WH_SLACK_URL:-}" bash -c ". '$WH_RS/config.sh'; webhook_pull; echo rc=\$?" 2>&1
}

test_wh_ac5_mac_pull_mirrors_events_and_advances_the_cursor() {
  wh_setup; mkdir -p "$WH_DIR/home/.claude/pipeline"; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local i=1; while [ "$i" -le 3 ]; do wh_post "$WH_DIR/b.json" "d-777777$i" issues >/dev/null; i=$((i + 1)); done
  local pipe="$WH_DIR/macpipe" out1 out2 seqs cur
  out1=$(we_pull "$pipe" "$WH_PORT"); out2=$(we_pull "$pipe" "$WH_PORT")
  seqs=$(jq -r '.seq' "$pipe/webhook/events.jsonl" | tr '\n' ','); cur=$(cat "$pipe/webhook/pull.cursor")
  wh_post "$WH_DIR/b.json" d-7777774 issues >/dev/null; we_pull "$pipe" "$WH_PORT" >/dev/null
  local seqs2; seqs2=$(jq -r '.seq' "$pipe/webhook/events.jsonl" | tr '\n' ',')
  wh_teardown
  assert_contains "$out1" "rc=0" "AC5: first pull succeeds" || return 1
  assert_contains "$out2" "rc=0" "AC5: second pull succeeds" || return 1
  assert_eq "$seqs" "1,2,3," "AC5: mirror has each event once (the second pull appended nothing)" || return 1
  assert_eq "$cur" "3" "AC5: cursor at the last appended seq" || return 1
  assert_eq "$seqs2" "1,2,3,4," "AC5: a later event is appended after the cursor" || return 1
}

test_wh_ac5_pull_with_a_wrong_token_appends_nothing_and_keeps_the_cursor() {
  wh_setup; mkdir -p "$WH_DIR/home/.claude/pipeline"; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"; wh_post "$WH_DIR/b.json" d-8888881 issues >/dev/null
  local pipe="$WH_DIR/macpipe" out; mkdir -p "$pipe/webhook"; echo 0 > "$pipe/webhook/pull.cursor"
  out=$(we_pull "$pipe" "$WH_PORT" "wrong-token-wrong-token")
  local n; n=$(wh_qlines "$pipe/webhook"); local cur; cur=$(cat "$pipe/webhook/pull.cursor")
  wh_teardown
  assert_contains "$out" "rc=1" "AC5: a refused pull reports failure" || return 1
  assert_eq "$n" "0" "AC5: nothing appended" || return 1
  assert_eq "$cur" "0" "AC5: cursor unchanged" || return 1
  assert_not_contains "$out" "wrong-token-wrong-token" "AC5: the token is never printed" || return 1
}

test_wh_ac5_a_reset_receiver_queue_forces_a_full_sync() {
  wh_setup; mkdir -p "$WH_DIR/home/.claude/pipeline"; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not start"; return 1; }
  wh_body "$WH_DIR/b.json" 7 "t"
  local i=1; while [ "$i" -le 3 ]; do wh_post "$WH_DIR/b.json" "d-999999$i" issues >/dev/null; i=$((i + 1)); done
  local pipe="$WH_DIR/macpipe"; we_pull "$pipe" "$WH_PORT" >/dev/null
  wh_stop; rm -rf "$WH_STATE"; wh_start "$WH_STATE" || { wh_teardown; fail "receiver did not restart"; return 1; }   # the VM lost its queue: seq starts over
  wh_post "$WH_DIR/b.json" d-9999994 issues >/dev/null
  we_pull "$pipe" "$WH_PORT" >/dev/null
  local gap=no; [ -f "$pipe/webhook/gap" ] && gap=yes
  local seqs; seqs=$(jq -r '.seq' "$pipe/webhook/events.jsonl" 2>/dev/null | tr '\n' ',')
  wh_teardown
  assert_eq "$gap" "yes" "AC5: queue reset on the VM -> gap marker (every repo full-syncs)" || return 1
  assert_eq "$seqs" "1," "AC5: the stale mirror was dropped and re-pulled" || return 1
}

# ---- AC6 / AC9: the read path ---------------------------------------------------------------------------------------------------
we_setup() {
  WE=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-we.XXXXXX"); mkdir -p "$WE/bin" "$WE/pipe" "$WE/home/.claude/pipeline"; : > "$WE/calls.log"
  echo '[]' > "$WE/since-resp.json"
  cat > "$WE/bin/gh" <<EOF
#!/bin/bash
D="$WE"
printf '%s\n' "\$*" >> "\$D/calls.log"
if [ "\$1 \$2" = "api rate_limit" ]; then printf '5000\t9999999999\t5000\t9999999999\n'; exit 0; fi
case "\$*" in
  *"issues?state=all"*"since="*) cat "\$D/since-resp.json"; exit 0 ;;
  *"api repos/example-owner/project-a/issues/"*) n="\${2##*/}"; echo "{\"number\":\$n}"; exit 0 ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$WE/bin/gh"
}
we_teardown() { rm -rf "$WE"; }
# we_tick <enabled 0|1> <bash text> — a fresh process like one supervisor tick: config.sh sourced, then the text
we_tick() {
  PATH="$WE/bin:$PATH" PIPE="$WE/pipe" LOGDIR="$WE/log" HOME="$WE/home" GH_BUDGET_ENABLED=1 WEBHOOK_EVENTS_ENABLED="$1" WEBHOOK_OWNERS="example-owner" \
    bash -c ". '$WH_RS/config.sh'; $2" 2>"$WE/err"
}
we_calls() { grep -c -- "$1" "$WE/calls.log" 2>/dev/null | tr -d ' '; }
we_age_cache() {  # make every cached read look an hour old: only a no-TTL trust can serve it
  local f; for f in "$WE/pipe/gh-cache"/[0-9]*; do [ -f "$f" ] && { { echo 1000; tail -n +2 "$f"; } > "$f.t"; mv "$f.t" "$f"; }; done
}
we_event() {  # <seq> <number|null> — append one queue line
  mkdir -p "$WE/pipe/webhook"
  printf '{"seq":%s,"ts":%s,"delivery":"d-%s","event":"issues","action":"edited","repo":"Example-Owner/Project-A","owner":"example-owner","number":%s,"sender":"octo-user"}\n' "$1" "$(date +%s)" "$1" "$2" >> "$WE/pipe/webhook/events.jsonl"
}
WE_SYNC='webhook_tick_prepare; gh_since_sync example-owner/project-a'

test_wh_ac6_only_the_touched_issue_is_re_read_and_no_list_call_is_made() {
  we_setup
  we_event 1 99
  we_tick 1 "$WE_SYNC; gh api repos/example-owner/project-a/issues/5 >/dev/null; gh api repos/example-owner/project-a/issues/6 >/dev/null"   # tick 1: cold, reads both
  we_age_cache
  we_event 2 5                                                                                                                             # an event for issue 5 only
  we_tick 1 "$WE_SYNC; gh api repos/example-owner/project-a/issues/5 >/dev/null; gh api repos/example-owner/project-a/issues/6 >/dev/null"
  local since five six; since=$(we_calls 'issues?state=all'); five=$(we_calls 'issues/5$'); six=$(we_calls 'issues/6$')
  we_teardown
  assert_eq "$since" "0" "AC6: no issues?since= list call on a tick the queue covers" || return 1
  assert_eq "$five" "2" "AC6: the touched issue was re-read (tick 1 + tick 2)" || return 1
  assert_eq "$six" "1" "AC6: the untouched issue was served from the cache (tick 1 only)" || return 1
}

test_wh_ac6_fallback_poll_runs_when_due_and_heals_a_dropped_event() {
  we_setup
  we_event 1 99
  we_tick 1 "$WE_SYNC; gh api repos/example-owner/project-a/issues/5 >/dev/null"   # tick 1 (cold) stamps the repo's full sync
  we_age_cache
  # a delivery was dropped: issue 5 changed, no event for it; the repo's fallback poll is now overdue and GitHub reports 5 as changed
  echo $(( $(date +%s) - 25 * 60 )) > "$WE/pipe/webhook/full.example-owner_project-a"
  echo '[{"number":5}]' > "$WE/since-resp.json"; we_event 2 99
  we_tick 1 "$WE_SYNC; gh api repos/example-owner/project-a/issues/5 >/dev/null"
  local since five stamp_age
  since=$(we_calls 'issues?state=all'); five=$(we_calls 'issues/5$')
  stamp_age=$(( $(date +%s) - $(cat "$WE/pipe/webhook/full.example-owner_project-a") ))
  we_tick 1 "$WE_SYNC" ; local since_after; since_after=$(we_calls 'issues?state=all')
  we_teardown
  assert_eq "$since" "1" "AC6: the overdue repo did its full since-sync" || return 1
  assert_eq "$five" "2" "AC6: the issue whose event was dropped was still picked up and re-read" || return 1
  [ "$stamp_age" -lt 60 ] || { fail "AC6: the full-sync stamp was not refreshed ($stamp_age s old)"; return 1; }
  assert_eq "$since_after" "1" "AC6: the next tick is event-only again (still one since call in total)" || return 1
}

test_wh_ac6_a_gap_forces_every_repo_to_full_sync() {
  we_setup
  we_event 5 99
  we_tick 1 "$WE_SYNC"
  echo 9 > "$WE/pipe/webhook/consumer.cursor"   # cursor ahead of the queue: the queue was reset
  we_tick 1 "$WE_SYNC"
  local since; since=$(we_calls 'issues?state=all')
  we_teardown
  assert_eq "$since" "1" "AC6: a reset queue drops the full-sync stamps, so the repo does a full sync" || return 1
}

test_wh_ac6_a_repo_whose_owner_has_no_webhook_keeps_the_plain_since_sync() {
  we_setup
  we_event 1 99
  local both='webhook_tick_prepare; gh_since_sync example-owner/project-a; gh_since_sync zzz-owner/project-b'
  we_tick 1 "$both"; we_tick 1 "$both"   # tick 1 cold for both; tick 2: the hooked repo is served from events, the other still syncs
  local hooked other; hooked=$(we_calls 'example-owner/project-a/issues?state=all'); other=$(we_calls 'zzz-owner/project-b/issues?state=all')
  we_teardown
  assert_eq "$hooked" "0" "AC6: a repo of a hooked owner makes no list call on a covered tick" || return 1
  assert_eq "$other" "1" "AC6: a repo with no hook still makes its since-sync call every tick" || return 1
}

test_wh_ac9_off_is_the_old_behaviour_and_writes_no_webhook_state() {
  we_setup
  we_event 1 5   # a queue left behind must be ignored
  rm -rf "$WE/pipe/webhook"; mkdir -p "$WE/pipe/webhook"; we_event 1 5
  we_tick 0 "$WE_SYNC"
  we_tick 0 "$WE_SYNC"
  local since files; since=$(we_calls 'issues?state=all'); files=$(ls "$WE/pipe/webhook" | tr '\n' ' ')
  local flag; flag=$(we_tick 0 'echo "$WEBHOOK_EVENTS_ENABLED"')
  local dflt; dflt=$(PIPE="$WE/pipe" HOME="$WE/home" bash -c 'unset WEBHOOK_EVENTS_ENABLED; . "'"$WH_RS"'/config.sh"; echo "$WEBHOOK_EVENTS_ENABLED"' 2>/dev/null)
  we_teardown
  assert_eq "$since" "1" "AC9: off = the unchanged since-sync (cold tick none, second tick one list call)" || return 1
  assert_eq "$files" "events.jsonl " "AC9: off = no cursor / stamp / enabled-since files are written" || return 1
  assert_eq "$dflt" "0" "AC9: the kill switch defaults to 0" || return 1
  assert_eq "$flag" "0" "AC9: an explicit 0 stays 0" || return 1
}

test_wh_ac9_example_config_documents_the_switch_and_secret_placeholders_are_empty() {
  local ex="$WH_RS/config.local.example.sh"
  assert_contains "$(cat "$ex")" 'WEBHOOK_EVENTS_ENABLED=1' "AC9: documented override" || return 1
  assert_contains "$(cat "$ex")" '# WEBHOOK_SECRET=""' "AC9: secret placeholder is empty" || return 1
  assert_contains "$(cat "$ex")" '# WEBHOOK_PULL_TOKEN=""' "AC9: token placeholder is empty" || return 1
  assert_contains "$(grep -n 'WEBHOOK_EVENTS_ENABLED=' "$WH_RS/config.sh")" '${WEBHOOK_EVENTS_ENABLED:-0}' "AC9: default 0 in config.sh" || return 1
}

# ---- AC7 (host side; #782: the VM receiver's last event time, never the Mac's own apply) -----------------------------------------
# VM = WEBHOOK_RECEIVER_URL empty (it reads the receiver's own queue file); Mac = the URL is set (its queue is a mirror).
WE_MAC_URL='https://hooks.example.invalid'
test_wh_ac7_vm_publishes_the_receiver_last_event_time_only_while_stale() {
  we_setup; mkdir -p "$WE/pipe/webhook"
  local now old; now=$(date +%s); old=$((now - 31 * 60))
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"o/r","number":1}\n' "$old" > "$WE/pipe/webhook/events.jsonl"
  local stale fresh off empty_since
  stale=$(we_tick 1 'webhook_last_event_at_json')
  printf '{"seq":2,"ts":%s,"delivery":"d-2","event":"issues","repo":"o/r","number":1}\n' "$now" >> "$WE/pipe/webhook/events.jsonl"
  fresh=$(we_tick 1 'webhook_last_event_at_json')
  rm "$WE/pipe/webhook/events.jsonl"; echo $((now - 40 * 60)) > "$WE/pipe/webhook/enabled-since"
  empty_since=$(we_tick 1 'webhook_last_event_at_json')
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"o/r","number":1}\n' "$old" > "$WE/pipe/webhook/events.jsonl"
  off=$(we_tick 0 'webhook_last_event_at_json')
  we_teardown
  assert_eq "$(printf '%s' "$stale" | jq -r 'fromdateiso8601')" "$old" "AC7: 31 minutes old -> the newest event's time, a JSON string" || return 1
  assert_eq "$fresh" "" "AC7: a fresh event -> nothing" || return 1
  assert_eq "$(printf '%s' "$empty_since" | jq -r 'fromdateiso8601')" "$((now - 40 * 60))" "AC7: an empty queue is measured from the enable time" || return 1
  assert_eq "$off" "" "AC7: kill switch off -> nothing" || return 1
}

test_wh_ac7_mac_publishes_nothing_even_when_its_mirror_is_old_or_empty() {
  we_setup; mkdir -p "$WE/pipe/webhook"
  local now old; now=$(date +%s); old=$((now - 90 * 60))
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"o/r","number":1}\n' "$old" > "$WE/pipe/webhook/events.jsonl"
  local old_mirror empty_mirror
  old_mirror=$(WEBHOOK_RECEIVER_URL="$WE_MAC_URL" we_tick 1 'webhook_last_event_at_json')
  rm "$WE/pipe/webhook/events.jsonl"; echo $((now - 90 * 60)) > "$WE/pipe/webhook/enabled-since"
  empty_mirror=$(WEBHOOK_RECEIVER_URL="$WE_MAC_URL" we_tick 1 'webhook_last_event_at_json')
  we_teardown
  assert_eq "$old_mirror" "" "AC4: a Mac with a 90 minute old mirror publishes no webhook time (it may just have been asleep)" || return 1
  assert_eq "$empty_mirror" "" "AC4: nor does a Mac with an empty mirror" || return 1
}

test_wh_ac7_reporter_payload_has_webhook_last_event_at_on_the_vm_only_and_never_webhook_stale() {
  we_setup; mkdir -p "$WE/pipe/webhook" "$WE/pipe/queue"
  local old; old=$(( $(date +%s) - 31 * 60 ))
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"o/r","number":1}\n' "$old" > "$WE/pipe/webhook/events.jsonl"
  local vm mac off legacy
  local env_base="PIPE=$WE/pipe QUEUE=$WE/pipe/queue HOME=$WE/home STATUS_CRON_CMD=true"
  vm=$(env $env_base WEBHOOK_EVENTS_ENABLED=1 "$WH_RS/report-status.sh" --print 2>/dev/null)
  mac=$(env $env_base WEBHOOK_EVENTS_ENABLED=1 WEBHOOK_RECEIVER_URL="$WE_MAC_URL" "$WH_RS/report-status.sh" --print 2>/dev/null)
  off=$(env $env_base WEBHOOK_EVENTS_ENABLED=0 "$WH_RS/report-status.sh" --print 2>/dev/null)
  we_teardown
  assert_eq "$(printf '%s' "$vm" | jq -r '.webhook_last_event_at | fromdateiso8601')" "$old" "AC4: the VM beat carries the receiver's last event time while stale" || return 1
  assert_eq "$(printf '%s' "$vm$mac$off" | jq -s 'map(has("webhook_stale")) | any')" "false" "AC4: no host publishes webhook_stale any more" || return 1
  assert_eq "$(printf '%s' "$mac" | jq -c 'has("webhook_last_event_at")')" "false" "AC4: the Mac beat has no webhook time" || return 1
  assert_eq "$(printf '%s' "$off" | jq -c 'has("webhook_last_event_at")')" "false" "AC7/AC9: off -> the key is absent" || return 1
}

test_wh_ac7_the_webhook_time_is_constant_while_stale_so_the_beat_hash_does_not_churn() {
  we_setup; mkdir -p "$WE/pipe/webhook" "$WE/pipe/queue"
  local old; old=$(( $(date +%s) - 31 * 60 ))
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"o/r","number":1}\n' "$old" > "$WE/pipe/webhook/events.jsonl"
  local a b
  a=$(PIPE="$WE/pipe" QUEUE="$WE/pipe/queue" HOME="$WE/home" WEBHOOK_EVENTS_ENABLED=1 STATUS_CRON_CMD=true "$WH_RS/report-status.sh" --print 2>/dev/null | jq -c '.webhook_last_event_at')
  sleep 1
  b=$(PIPE="$WE/pipe" QUEUE="$WE/pipe/queue" HOME="$WE/home" WEBHOOK_EVENTS_ENABLED=1 STATUS_CRON_CMD=true "$WH_RS/report-status.sh" --print 2>/dev/null | jq -c '.webhook_last_event_at')
  we_teardown
  assert_eq "$a" "$b" "AC4: the same stale feed publishes the same value on every tick (no KV write churn)" || return 1
}

# ---- AC12 -----------------------------------------------------------------------------------------------------------------------
wh_slack_start() {  # sets WH_SLACK_URL, WH_SLACK_OUT
  WH_SLACK_OUT="$WH_DIR/slack.out"; : > "$WH_SLACK_OUT"
  cat > "$WH_DIR/slack.py" <<'EOF'
import sys, http.server
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        with open(out, 'ab') as fh:
            fh.write(self.rfile.read(n) + b'\n')
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
  python3 "$WH_DIR/slack.py" "$WH_SLACK_OUT" > "$WH_DIR/slack.port" 2>/dev/null &
  WH_PIDS="$WH_PIDS $!"
  local port; port=$(wh_wait_line "$WH_DIR/slack.port") || return 1
  WH_SLACK_URL="http://127.0.0.1:$port/hook"
}

test_wh_ac12_a_receiver_error_is_captured_with_tags_and_no_secrets() {
  wh_setup; wh_slack_start || { wh_teardown; fail "fake slack did not start"; return 1; }
  wh_start "$WH_STATE" SLACK_WEBHOOK_URL="$WH_SLACK_URL" || { wh_teardown; fail "receiver did not start"; return 1; }
  mkdir -p "$WH_STATE/events.jsonl"   # the queue file becomes unwritable (a directory): the append raises
  wh_body "$WH_DIR/b.json" 7 "t"
  local code; code=$(wh_post "$WH_DIR/b.json" d-1212121 issues)
  sleep 0.5
  local slack err; slack=$(cat "$WH_SLACK_OUT"); err=$(cat "$WH_ERR")
  wh_teardown
  assert_eq "$code" "500" "AC12: the failing append is a 500, not a crash" || return 1
  assert_contains "$slack" "release=" "AC12: Slack alert carries the release tag" || return 1
  assert_contains "$slack" "environment=" "AC12: Slack alert carries the environment tag" || return 1
  assert_contains "$slack" "route=webhook-receiver" "AC12: Slack alert carries the route tag" || return 1
  assert_not_contains "$slack$err" "$WH_SECRET" "AC12: the secret is never logged or alerted" || return 1
  assert_not_contains "$slack$err" "$WH_TOKEN" "AC12: the pull token is never logged or alerted" || return 1
  assert_not_contains "$slack$err" "private text" "AC12: no payload text in logs or alerts" || return 1
}

test_wh_ac12_a_failed_pull_is_captured_with_tags_and_no_token() {
  wh_setup; mkdir -p "$WH_DIR/home/.claude/pipeline"; wh_slack_start || { wh_teardown; fail "fake slack did not start"; return 1; }
  WH_SLACK_URL="$WH_SLACK_URL" we_pull "$WH_DIR/macpipe" 1 >/dev/null   # nothing listens on port 1: the pull fails
  local slack; slack=$(cat "$WH_SLACK_OUT"); local again
  WH_SLACK_URL="$WH_SLACK_URL" we_pull "$WH_DIR/macpipe" 1 >/dev/null; again=$(grep -c . "$WH_SLACK_OUT" | tr -d ' ')
  WH_SLACK_URL=""
  wh_teardown
  assert_contains "$slack" "route=webhook-events" "AC12: route tag on the shell path" || return 1
  assert_contains "$slack" "release=" "AC12: release tag on the shell path" || return 1
  assert_contains "$slack" "environment=" "AC12: environment tag on the shell path" || return 1
  assert_not_contains "$slack" "$WH_TOKEN" "AC12: no token in the alert" || return 1
  assert_eq "$again" "1" "AC12: at most one Slack post per hour while the pull keeps failing" || return 1
}

# ---- constant-time compares, launcher kill switch, the :-0 fallback ---------------------------------------------------------------
test_wh_ac3_signature_and_token_use_hmac_compare_digest_never_equality() {
  local py="$WH_RS/webhook-receiver.py" code n sig_line tok_line bad
  code=$(grep -v '^[[:space:]]*#' "$py")
  n=$(printf '%s\n' "$code" | grep -c 'hmac\.compare_digest(')
  sig_line=$(printf '%s\n' "$code" | grep 'hmac\.compare_digest(expected')
  tok_line=$(printf '%s\n' "$code" | grep 'hmac\.compare_digest(got')
  # any == / != / in involving the computed digest, the presented signature, the bearer token or the configured secrets
  bad=$(printf '%s\n' "$code" | grep -nE '(expected|got|cfg\.token|cfg\.secret|match\.group\(1\)|hexdigest\(\))[^#]*(==|!=)|(==|!=)[^#]*(expected|got\b|cfg\.token|cfg\.secret|match\.group\(1\)|hexdigest\(\))')
  [ "$n" -ge 2 ] || { fail "expected at least 2 hmac.compare_digest calls, found $n"; return 1; }
  assert_ne "$sig_line" "" "the signature is compared with hmac.compare_digest(expected, ...)" || return 1
  assert_ne "$tok_line" "" "the /events bearer token is compared with hmac.compare_digest(got, ...)" || return 1
  assert_eq "$bad" "" "neither the signature nor the token is compared with == or !=" || return 1
}

test_wh_ac9_launcher_does_not_start_with_the_switch_unset_or_zero() {
  wh_setup; mkdir -p "$WH_DIR/home/.claude/pipeline"
  local port; port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  local rc_unset rc_zero err_unset err_zero listening
  err_unset=$(env -u WEBHOOK_EVENTS_ENABLED HOME="$WH_DIR/home" PIPE="$WH_DIR/pipe" WEBHOOK_SECRET="$WH_SECRET" WEBHOOK_PULL_TOKEN="$WH_TOKEN" WEBHOOK_PORT="$port" \
    bash "$WH_RS/webhook-receiver.sh" 2>&1 >/dev/null); rc_unset=$?
  err_zero=$(HOME="$WH_DIR/home" PIPE="$WH_DIR/pipe" WEBHOOK_EVENTS_ENABLED=0 WEBHOOK_SECRET="$WH_SECRET" WEBHOOK_PULL_TOKEN="$WH_TOKEN" WEBHOOK_PORT="$port" \
    bash "$WH_RS/webhook-receiver.sh" 2>&1 >/dev/null); rc_zero=$?
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/health" && listening=yes || listening=no
  wh_teardown
  assert_eq "$rc_unset $rc_zero" "0 0" "launcher exits 0 (so Restart=on-failure leaves it down) with the switch unset and 0" || return 1
  assert_contains "$err_unset" "not starting" "unset: says it is not starting" || return 1
  assert_contains "$err_zero" "not starting" "0: says it is not starting" || return 1
  assert_eq "$listening" "no" "nothing is listening on the configured port" || return 1
  assert_not_contains "$err_unset$err_zero" "$WH_SECRET" "the secret is not echoed" || return 1
}

test_wh_ac9_switch_defaults_to_off_inside_the_library_files_themselves() {
  we_setup; mkdir -p "$WE/pipe/webhook"
  local now; now=$(date +%s)
  printf '{"seq":1,"ts":%s,"delivery":"d-1","event":"issues","repo":"example-owner/project-a","number":5}\n' "$((now - 31 * 60))" > "$WE/pipe/webhook/events.jsonl"
  echo 1 > "$WE/pipe/webhook/consumer.cursor"; echo "$now" > "$WE/pipe/webhook/applied"; echo "$now" > "$WE/pipe/webhook/full.example-owner_project-a"
  local before after calls trusted stale
  before=$(ls "$WE/pipe/webhook" | tr '\n' ' ')
  # gh-budget.sh and webhook-events.sh sourced alone (no config.sh default), the runner's export removed: only their own ${WEBHOOK_EVENTS_ENABLED:-0} decides
  stale=$(env -u WEBHOOK_EVENTS_ENABLED PATH="$WE/bin:$PATH" PIPE="$WE/pipe" LOGDIR="$WE/log" HOME="$WE/home" GH_BUDGET_ENABLED=1 \
    bash -c ". '$WH_RS/gh-budget.sh'; . '$WH_RS/webhook-events.sh'
      webhook_tick_prepare; gh_since_sync example-owner/project-a; gh_since_sync example-owner/project-a
      webhook_trusted example-owner/project-a && echo TRUSTED
      webhook_last_event_at_json" 2>/dev/null)
  calls=$(we_calls 'issues?state=all'); after=$(ls "$WE/pipe/webhook" | tr '\n' ' ')
  we_teardown
  assert_eq "$calls" "1" "unset switch: the second since-sync still makes its API call (cold, then one list call)" || return 1
  assert_eq "$stale" "" "unset switch: not trusted, no webhook time field" || return 1
  assert_eq "$after" "$before" "unset switch: webhook_tick_prepare wrote no state" || return 1
}

# ---- code-review follow-ups ---------------------------------------------------------------------------------------------------
test_wh_runbook_never_puts_the_secret_on_an_argv() {
  local doc; doc=$(cat "$WH_RS/../../docs/webhook-events.md"); local unit; unit=$(cat "$WH_RS/../../infra/webhook/webhook-receiver.service")
  assert_not_contains "$doc" '--arg secret' "runbook: jq --arg would put the HMAC key in ps" || return 1
  assert_not_contains "$doc" 'config[secret]' "runbook: gh -f config[secret]= would put it in argv" || return 1
  assert_contains "$doc" 'secret:env.WEBHOOK_SECRET' "runbook: the secret reaches jq through the environment" || return 1
  assert_contains "$doc" 'export WEBHOOK_SECRET' "runbook: the variable is exported before jq reads env" || return 1
  assert_contains "$doc" 'chmod 600 ~/.claude/pipeline/config.local.sh' "runbook: an existing secrets file is tightened" || return 1
  assert_contains "$unit" 'RestartPreventExitStatus=2' "unit: a missing-secrets exit does not restart-loop" || return 1
}

test_wh_ac6_a_cursor_further_back_than_the_read_window_forces_a_full_sync() {
  we_setup; mkdir -p "$WE/pipe/webhook"
  awk -v t="$(date +%s)" 'BEGIN{for(i=1;i<=5100;i++) printf "{\"seq\":%d,\"ts\":%d,\"delivery\":\"d-%d\",\"event\":\"issues\",\"repo\":\"example-owner/project-a\",\"number\":1}\n", i, t, i}' > "$WE/pipe/webhook/events.jsonl"
  echo 1 > "$WE/pipe/webhook/consumer.cursor"; date +%s > "$WE/pipe/webhook/full.example-owner_project-a"
  we_tick 1 'webhook_tick_prepare'
  local stamp=kept; [ -f "$WE/pipe/webhook/full.example-owner_project-a" ] || stamp=dropped
  # a cursor inside the window is not a gap
  echo 4000 > "$WE/pipe/webhook/consumer.cursor"; date +%s > "$WE/pipe/webhook/full.example-owner_project-a"
  we_tick 1 'webhook_tick_prepare'
  local inside=kept; [ -f "$WE/pipe/webhook/full.example-owner_project-a" ] || inside=dropped
  we_teardown
  assert_eq "$stamp" "dropped" "AC6: 5099 events behind (more than the 5000-line window) = gap, every repo full-syncs" || return 1
  assert_eq "$inside" "kept" "AC6: 1100 events behind is read normally" || return 1
}

test_wh_ac6_other_processes_do_not_trust_the_cache_while_an_event_is_unapplied() {
  we_setup; mkdir -p "$WE/pipe/webhook"
  we_event 1 99
  we_tick 1 "$WE_SYNC"                                   # tick: applied-ref + applied + full stamp are fresh
  local fresh unapplied
  fresh=$(we_tick 1 'webhook_trusted example-owner/project-a; echo $?')
  touch -t 202001010000 "$WE/pipe/webhook/applied-ref"   # the queue is now newer than the last apply = an event arrived since
  unapplied=$(we_tick 1 'webhook_trusted example-owner/project-a; echo $?')
  we_tick 1 "$WE_SYNC"                                   # the next tick applies it
  local applied; applied=$(we_tick 1 'webhook_trusted example-owner/project-a; echo $?')
  we_teardown
  assert_eq "$fresh $unapplied $applied" "0 1 0" "AC6: trusted after an apply, not trusted while a newer event is unapplied, trusted again after the next tick" || return 1
}

run_test test_wh_runbook_never_puts_the_secret_on_an_argv
run_test test_wh_ac6_a_cursor_further_back_than_the_read_window_forces_a_full_sync
run_test test_wh_ac6_other_processes_do_not_trust_the_cache_while_an_event_is_unapplied
run_test test_wh_ac1_bad_signatures_are_401_and_queue_nothing
run_test test_wh_ac3_signature_and_token_use_hmac_compare_digest_never_equality
run_test test_wh_ac9_launcher_does_not_start_with_the_switch_unset_or_zero
run_test test_wh_ac9_switch_defaults_to_off_inside_the_library_files_themselves
run_test test_wh_ac1_valid_signed_issue_is_202_and_stores_tags_only
run_test test_wh_ac1_ping_and_unlisted_events_are_not_queued
run_test test_wh_ac2_replayed_delivery_is_queued_once_across_restart
run_test test_wh_ac3_oversize_body_is_413
run_test test_wh_ac3_rate_limit_121st_request_is_429
run_test test_wh_ac3_method_and_path_allow_list
run_test test_wh_ac3_events_requires_the_bearer_token
run_test test_wh_ac3_refuses_to_start_without_both_secrets
run_test test_wh_ac4_shell_metacharacters_in_a_payload_create_nothing
run_test test_wh_ac4_no_eval_or_shell_execution_in_receiver_and_consumers
run_test test_wh_ac5_events_since_returns_only_newer_events_in_order
run_test test_wh_ac5_mac_pull_mirrors_events_and_advances_the_cursor
run_test test_wh_ac5_pull_with_a_wrong_token_appends_nothing_and_keeps_the_cursor
run_test test_wh_ac5_a_reset_receiver_queue_forces_a_full_sync
run_test test_wh_ac6_only_the_touched_issue_is_re_read_and_no_list_call_is_made
run_test test_wh_ac6_fallback_poll_runs_when_due_and_heals_a_dropped_event
run_test test_wh_ac6_a_gap_forces_every_repo_to_full_sync
run_test test_wh_ac6_a_repo_whose_owner_has_no_webhook_keeps_the_plain_since_sync
run_test test_wh_ac9_off_is_the_old_behaviour_and_writes_no_webhook_state
run_test test_wh_ac9_example_config_documents_the_switch_and_secret_placeholders_are_empty
run_test test_wh_ac7_vm_publishes_the_receiver_last_event_time_only_while_stale
run_test test_wh_ac7_mac_publishes_nothing_even_when_its_mirror_is_old_or_empty
run_test test_wh_ac7_reporter_payload_has_webhook_last_event_at_on_the_vm_only_and_never_webhook_stale
run_test test_wh_ac7_the_webhook_time_is_constant_while_stale_so_the_beat_hash_does_not_churn
run_test test_wh_ac12_a_receiver_error_is_captured_with_tags_and_no_secrets
run_test test_wh_ac12_a_failed_pull_is_captured_with_tags_and_no_token
