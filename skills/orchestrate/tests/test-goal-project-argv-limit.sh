# #793: nothing large goes through argv. On Linux ONE command-line argument is capped at 131072 bytes (MAX_ARG_STRLEN); macOS has no such cap,
# so a `jq --argjson acc "$nodes"` over a >128KB accumulated project passed on the Mac and failed on the VM ("an items page does not parse").
# Every case runs with a fake `jq` first on PATH that refuses any argument of 131072 bytes or more with exit 126 and "Argument list too long",
# so the suite reproduces the Linux limit on the Mac too. Pages are 100 issues with 1.5KB bodies (about 165KB a page), so the accumulated
# result passes 200KB from page 2 on. Expected values are hand-written. Prefix av_.

AV_SRC_DIR="${AV_SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"   # override to run the suite against another checkout of the scripts

av_setup() {  # av_setup -> sets AV_DIR (bin/, pages/, tmp/); a jq that enforces the Linux per-argument cap; a gh that serves pages/N.json
  AV_DIR=$(mktemp -d "${TMPDIR:-/tmp}/av-test.XXXXXX"); mkdir -p "$AV_DIR/bin" "$AV_DIR/pages" "$AV_DIR/tmp"
  AV_REAL_JQ=$(command -v jq)
  cat > "$AV_DIR/bin/jq" <<AV_JQ_EOF
#!/bin/bash
export LC_ALL=C
for a in "\$@"; do
  if [ "\${#a}" -ge 131072 ]; then echo "jq: Argument list too long (argument of \${#a} bytes)" >&2; exit 126; fi
done
exec "$AV_REAL_JQ" "\$@"
AV_JQ_EOF
  cat > "$AV_DIR/bin/gh" <<'AV_GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
[ "$1" = api ] && [ "$2" = graphql ] || { echo "fake gh: unsupported $*" >&2; exit 1; }
case "$*" in *cursor=c2*) f="$D/pages/3.json" ;; *cursor=c1*) f="$D/pages/2.json" ;; *) f="$D/pages/1.json" ;; esac
[ -f "$f" ] || { echo "fake gh: no $f" >&2; exit 1; }
cat "$f"
AV_GH_EOF
  chmod +x "$AV_DIR/bin/jq" "$AV_DIR/bin/gh"
}

av_page() {  # av_page <file> <first number> <count> <next cursor or ""> <scope|items> -> one page of <count> issue nodes with 1.5KB bodies
  "$AV_REAL_JQ" -nc --argjson from "$2" --argjson n "$3" --arg next "$4" --arg kind "$5" '
    ([range(300) | "abcde"] | join("")) as $body
    | {pageInfo: {hasNextPage: ($next != ""), endCursor: (if $next == "" then null else $next end)},
       nodes: [range($from; $from + $n) | if $kind == "scope"
         then {type: "ISSUE", content: {number: ., state: "OPEN", stateReason: null, body: $body, author: {login: "u"}, labels: {nodes: [{name: "l"}]},
                milestone: null, repository: {nameWithOwner: "example-owner/project-a"}}}
         else {id: "I_\(.)", fieldValueByName: {name: "Todo"}, content: {number: ., state: "OPEN", repository: {nameWithOwner: "example-owner/project-a"},
                labels: {nodes: [range(0; 3) | {name: ([range(60) | "z"] | join(""))}]}}} end]}
    | {data: {repositoryOwner: {projectV2: ({title: "Goal: big", url: "https://github.com/users/example-owner/projects/41", closed: false}
        + {items: .})}}}' > "$1"
}

av_run() {  # av_run <function and args...> -> AV_OUT, AV_ERR, AV_RC (goal-project.sh sourced in a subshell, fake jq/gh first on PATH, private TMPDIR)
  AV_RC=0
  AV_OUT=$( cd "$AV_DIR" && PATH="$AV_DIR/bin:$PATH" TMPDIR="$AV_DIR/tmp" PIPE="$AV_DIR/pipe" bash -c '
    slog() { :; }
    . "$1/goal-project.sh"; shift
    "$@"' _ "$AV_SRC_DIR" "$@" 2>"$AV_DIR/err" ) || AV_RC=$?
  AV_ERR=$(cat "$AV_DIR/err")
}

av_no_leftovers() { [ -z "$(ls -A "$AV_DIR/tmp")" ]; }   # the reader's temp dir is gone

test_av_project_read_survives_the_linux_argument_cap_over_three_pages() {
  av_setup
  av_page "$AV_DIR/pages/1.json" 1 100 c1 scope; av_page "$AV_DIR/pages/2.json" 101 100 c2 scope; av_page "$AV_DIR/pages/3.json" 201 50 "" scope
  av_run goal_project_read example-owner 41
  local rc=0 left=0; av_no_leftovers || left=1
  assert_eq "$AV_RC" "0" "goal_project_read exits 0 over 250 issues (stderr: $AV_ERR)" || rc=1
  assert_eq "$(printf '%s' "$AV_OUT" | jq -c '[.title, (.issues | length), .issues[0].number, .issues[249].number, (.issues | map(.number) == [range(1; 251)])]')" \
    '["Goal: big",250,1,250,true]' "title, 250 issues, in page order" || rc=1
  assert_eq "$(printf '%s' "$AV_OUT" | jq -r '.issues[249].body | length')" "1500" "the last issue keeps its whole 1500 character body" || rc=1
  assert_eq "$left" "0" "no temp dir left behind on success" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

test_av_the_fake_jq_really_refuses_a_large_argument() {  # guards the guard: without this the cases above could pass for the wrong reason
  av_setup
  local big out rc=0
  big=$(head -c 140000 /dev/zero | tr '\0' x)
  out=$(PATH="$AV_DIR/bin:$PATH" jq -n --arg x "$big" '$x | length' 2>&1) && rc=1
  assert_contains "$out" "Argument list too long" "a 140000 byte argument is refused" || rc=1
  assert_eq "$(PATH="$AV_DIR/bin:$PATH" jq -n --arg x "short" '$x | length')" "5" "a small argument passes" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

test_av_project_items_survive_the_linux_argument_cap_over_three_pages() {
  av_setup
  av_page "$AV_DIR/pages/1.json" 1 400 c1 items; av_page "$AV_DIR/pages/2.json" 401 400 c2 items; av_page "$AV_DIR/pages/3.json" 801 100 "" items
  av_run _gp_items example-owner 41
  local rc=0 left=0; av_no_leftovers || left=1
  assert_eq "$AV_RC" "0" "_gp_items exits 0 over 900 items (stderr: $AV_ERR)" || rc=1
  assert_eq "$(printf '%s' "$AV_OUT" | jq -c '[(.items | length), .items[0].content.number, .items[899].content.number, (.items | map(.content.number) == [range(1; 901)])]')" \
    '[900,1,900,true]' "900 items, in page order" || rc=1
  assert_eq "$(( ${#AV_OUT} > 200000 ))" "1" "the merged result is over 200KB (it was ${#AV_OUT} bytes)" || rc=1
  assert_eq "$left" "0" "no temp dir left behind on success" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

test_av_a_bad_page_two_still_fails_closed_and_leaves_nothing_behind() {
  av_setup
  av_page "$AV_DIR/pages/1.json" 1 100 c1 scope; echo '{"data":{"repositoryOwner":{"projectV2":{"items":{"pageInfo":{"hasNextPage":false},"nodes":null}}}}}' > "$AV_DIR/pages/2.json"
  av_run goal_project_read example-owner 41
  local rc=0 left=0; av_no_leftovers || left=1
  assert_eq "$AV_RC" "1" "exit 1 when a later page has no nodes array" || rc=1
  assert_eq "$AV_ERR" "an items page does not parse" "the one reason line is the page-parse reason" || rc=1
  assert_eq "$AV_OUT" "" "no partial scope on stdout" || rc=1
  assert_eq "$left" "0" "no temp dir left behind on failure" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

test_av_a_failing_gh_on_page_two_leaves_nothing_behind() {
  av_setup
  av_page "$AV_DIR/pages/1.json" 1 100 c1 scope   # pages/2.json is missing: the fake gh exits 1 on the cursor call
  av_run goal_project_read example-owner 41
  local rc=0 left=0; av_no_leftovers || left=1
  assert_eq "$AV_RC" "1" "exit 1 when page 2 cannot be fetched" || rc=1
  assert_contains "$AV_ERR" "gh exit 1" "the gh failure is the reason" || rc=1
  assert_eq "$left" "0" "no temp dir left behind" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

test_av_status_payload_survives_the_linux_argument_cap() {
  av_setup
  local pipe home out rc=0 left=0
  pipe=$(new_pipe); home=$(new_home)
  "$AV_REAL_JQ" -nc '[range(1; 1501) | {owner_repo: "example-owner/project-a", issue: ., title: ([range(140) | "t"] | join("")), updated_at: "2026-11-19T10:00:00Z"}]' > "$pipe/status-approved.json"
  out=$( PATH="$AV_DIR/bin:$PATH" TMPDIR="$AV_DIR/tmp" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$AV_SRC_DIR/report-status.sh" --print 2>"$AV_DIR/err" ) || rc=1
  av_no_leftovers || left=1
  assert_eq "$rc" "0" "report-status.sh --print exits 0 (stderr: $(head -c 300 "$AV_DIR/err"))" || { rm -rf "$AV_DIR" "$pipe" "$home"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -c '[.v, (.approved | length), (.runs | length), .capacity.max]')" '[1,1500,0,3]' "payload built with 1500 approved tickets, other parts intact" || rc=1
  assert_eq "$(( ${#out} > 262144 ))" "1" "the approved list alone is past the 128KB cap (payload ${#out} bytes)" || rc=1
  assert_eq "$left" "0" "no payload temp dir left behind" || rc=1
  rm -rf "$AV_DIR" "$pipe" "$home"; return $rc
}

test_av_no_accumulated_json_is_passed_as_an_argument() {
  local rc=0 gp rs
  gp=$(grep -vE '^[[:space:]]*#' "$AV_SRC_DIR/goal-project.sh"); rs=$(grep -vE '^[[:space:]]*#' "$AV_SRC_DIR/report-status.sh")
  assert_not_contains "$gp" '--argjson acc' "goal-project.sh does not hand the accumulated pages to jq as an argument" || rc=1
  assert_not_contains "$gp" '--argjson l "$list"' "goal-project.sh does not hand the project list to jq as an argument" || rc=1
  assert_eq "$(printf '%s' "$rs" | grep -cE -e '--argjson (goals|goal_stall|runs|completed|staging|approved|backlog|triggers|ci_queue|cron|sentry_cap|webhook_last_event_at) ' || true)" "0" \
    "report-status.sh passes none of the payload parts as --argjson" || rc=1
  return $rc
}

test_av_every_temp_dir_is_removed_on_signals_too() {   # reviewer MEDIUM on #794: a signal must not leave ticket text in /tmp
  local rc=0 gp rs
  gp=$(grep -vE '^[[:space:]]*#' "$AV_SRC_DIR/goal-project.sh"); rs=$(grep -vE '^[[:space:]]*#' "$AV_SRC_DIR/report-status.sh")
  assert_eq "$(printf '%s' "$gp" | grep -c 'mktemp -d')" "1" "goal-project.sh makes its temp dirs in ONE helper (_gp_in_tmp)" || rc=1
  assert_contains "$gp" "trap 'rm -rf \"\$dir\"' EXIT" "the helper removes the dir on exit" || rc=1
  assert_contains "$gp" "trap 'exit 130' INT; trap 'exit 143' TERM" "and on INT and TERM (the exit fires the EXIT trap)" || rc=1
  assert_contains "$rs" "trap 'rm -rf \"\$d\"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM" "report-status.sh does the same for its payload dir" || rc=1
  return $rc
}

test_av_a_signalled_read_leaves_no_temp_dir_behind() {
  av_setup
  av_page "$AV_DIR/pages/1.json" 1 100 c1 scope
  cp "$(command -v sleep)" "$AV_DIR/bin/avsleep"   # a private copy: every kill below names $AV_DIR, never a bare process name
  cat > "$AV_DIR/bin/gh" <<'AV_SLOW_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
case "$*" in *cursor=c1*) : > "$D/second-call"; exec "$D/bin/avsleep" 30 ;; esac
cat "$D/pages/1.json"
AV_SLOW_EOF
  chmod +x "$AV_DIR/bin/gh"
  ( cd "$AV_DIR" && PATH="$AV_DIR/bin:$PATH" TMPDIR="$AV_DIR/tmp" PIPE="$AV_DIR/pipe" bash -c '. "$1/goal-project.sh"; goal_project_read example-owner 41' _ "$AV_SRC_DIR" "$AV_DIR" >/dev/null 2>&1 ) &
  local bg=$! i=0 rc=0
  while [ ! -e "$AV_DIR/second-call" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  # TERM every shell of the read (the one that owns the dir is a fork of it), then end the blocked gh so the deferred trap can run
  pkill -TERM -f "bash -c .*goal_project_read example-owner 41.*$AV_DIR" 2>/dev/null
  sleep 0.3; pkill -f "$AV_DIR/bin/avsleep" 2>/dev/null; wait "$bg" 2>/dev/null
  i=0; while [ -n "$(ls -A "$AV_DIR/tmp" 2>/dev/null)" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  assert_eq "$(ls -A "$AV_DIR/tmp")" "" "no temp dir left after the reader was terminated mid-read" || rc=1
  rm -rf "$AV_DIR"; return $rc
}

for t in test_av_the_fake_jq_really_refuses_a_large_argument test_av_project_read_survives_the_linux_argument_cap_over_three_pages \
         test_av_project_items_survive_the_linux_argument_cap_over_three_pages test_av_a_bad_page_two_still_fails_closed_and_leaves_nothing_behind \
         test_av_a_failing_gh_on_page_two_leaves_nothing_behind test_av_status_payload_survives_the_linux_argument_cap \
         test_av_no_accumulated_json_is_passed_as_an_argument test_av_every_temp_dir_is_removed_on_signals_too \
         test_av_a_signalled_read_leaves_no_temp_dir_behind; do
  run_test "$t"
done
