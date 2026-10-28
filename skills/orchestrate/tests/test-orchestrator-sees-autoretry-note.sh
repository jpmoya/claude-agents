# The orchestrator must SEE the supervisor's auto-retry NOTE through its own marker read — behavioural, end to end.
#
# Root cause (two audits, 2026-10-28): the supervisor resumes a parked BLOCKED (ci_pending | ci_red | merge_conflict |
# dependency) by posting `**[supervisor] NOTE** auto-retry <n>/<max>: <cls> cleared` and relaunching the orchestrator.
# The orchestrator's resume row (#269) keys on that NOTE, but `markers()` — the one helper agents/orchestrator.md tells it
# to read state with — filtered out every NOTE, so a relaunch saw only the BLOCKED and re-exited for JP. #158, #269,
# #271, #306, #439 and #484 all changed the writer (when/how the supervisor posts) and pinned the reader with text greps
# only (test-issue269-orchestrator-autoretry-route.sh), so none of them noticed that the reader could not see the NOTE.
#
# These cases close that gap by running the REAL code on both ends:
#   writer  the NOTE body is captured from a real supervisor.sh tick (fake gh), never hand-typed — a change to the
#           supervisor's wording breaks this test instead of silently blinding the orchestrator again;
#   reader  markers() and the Gate-marker command are extracted from agents/orchestrator.md (the text the orchestrator
#           copies and runs) and executed against a paginating fake `gh api` holding a realistic comment thread.
# Prefixed oa_ / OA_.

HERE_OA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_OA=$(cd "$HERE_OA/../../.." && pwd)
ORCH_OA="$ROOT_OA/agents/orchestrator.md"
MARKERS_OA="$ROOT_OA/hooks/pipeline-markers.sh"
SUP_OA="$HERE_OA/../supervisor.sh"

# Load the ar2_* / cr_* supervisor fixtures without running their cases (same trick as test-supervisor-ci-rerun.sh).
if ! declare -f cr_fixture >/dev/null 2>&1; then
  eval "oa_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_OA/test-supervisor-ci-rerun.sh"
  eval "$(declare -f oa_real_run_test | sed '1s/oa_real_run_test/run_test/')"
fi

OA_BLOCKED=$'**[deployer] BLOCKED**\nBlocked on: ci_pending — required checks still running on PR #7'

# ------------------------------------------------------------------------------------------ writer side

# oa_writer_note ci_pending|infra — runs real supervisor.sh tick(s) on a held run #42 and prints the exact body of the
# auto-retry NOTE it posted (from the fake gh's call log). ci_pending: checks went green. infra: a ci_red whose only
# failures after one re-run are infrastructure-class, so the supervisor appends ` — <detail>` (#473).
oa_writer_note() {
  case "$1" in
    ci_pending)
      ar2_fixture 'Blocked on: ci_pending — required checks still running on PR #7' '**[deployer] BLOCKED**'
      echo pass > "$SQ_GH/gh-pr-checks"
      ar2_tick; ar2_launches >/dev/null; sleep 0.5 ;;   # let the async launch finish writing before sq_cleanup
    infra)
      cr_fixture $'##[group]Initialize containers\n##[error]Error response from daemon' $'> next build\nProcess completed with exit code 137.'
      ar2_tick; cr_force_next_check; ar2_tick; cr_settle ;;
  esac
  gh_calls "$SQ_GH" | sed -n 's/^issue comment 42 --body //p' | tail -1
  sq_cleanup
}

# ------------------------------------------------------------------------------------------ reader side

# oa_setup — OA_DIR with bin/gh: a fake that behaves like `gh api ... --paginate --jq <expr>` (the filter runs on each
# page separately, outputs concatenated), and pages/page*.json fixtures. Anything but `gh api` exits 1.
oa_setup() {
  OA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-autoretry-note.XXXXXX")
  mkdir -p "$OA_DIR/bin" "$OA_DIR/pages" "$OA_DIR/work"
  cat > "$OA_DIR/bin/gh" <<EOF
#!/bin/bash
D="$OA_DIR"
[ "\$1" = "api" ] || { echo "fake gh: unsupported: \$*" >&2; exit 1; }
expr=""
while [ \$# -gt 0 ]; do
  case "\$1" in --jq) expr=\$2; shift ;; esac
  shift
done
for p in "\$D"/pages/page*.json; do
  [ -e "\$p" ] || continue
  if [ -n "\$expr" ]; then jq -r "\$expr" "\$p" || exit 1; else cat "\$p"; fi
done
exit 0
EOF
  chmod +x "$OA_DIR/bin/gh"
}
oa_teardown() { rm -rf "$OA_DIR"; }

# oa_comment <minute> <body> — one REST-shaped issue comment on #42, created 2026-10-28T10:<minute>:00Z
oa_comment() {
  jq -n --arg t "2026-10-28T10:$1:00Z" --arg b "$2" --arg u "https://github.com/o/r/issues/42#issuecomment-10$1" \
    '{created_at:$t, user:{login:"jpmoya"}, html_url:$u, body:$b}'
}

# oa_thread <note body> [extra comment body posted after the NOTE] — the incident shape, over two pages: a fast-lane
# ticket reviewed and PASSed, a claim NOTE, the deployer's ci_pending BLOCKED; page 2 holds the supervisor's NOTE.
oa_thread() {
  { oa_comment 00 $'**[product-manager] READY FOR ENGINEERING**\nUI change: no\nLane: fast'
    oa_comment 10 $'**[fullstack-developer] IMPLEMENTED**\nPR: #7'
    oa_comment 20 $'**[code-reviewer] PASS**\nreview'
    oa_comment 21 $'**[test-reviewer] PASS**\nreview'
    oa_comment 25 '**[supervisor] NOTE** claim: mac 2026-10-28T10:25:00Z'
    oa_comment 30 "$OA_BLOCKED"
  } | jq -s . > "$OA_DIR/pages/page1.json"
  { oa_comment 40 "$1"
    [ -z "${2:-}" ] || oa_comment 50 "$2"
  } | jq -s . > "$OA_DIR/pages/page2.json"
}

# oa_markers — the REAL markers() from agents/orchestrator.md, run as the orchestrator runs it (helpers sourced first).
oa_markers() {
  ( cd "$OA_DIR/work" && PATH="$OA_DIR/bin:$PATH" && . "$MARKERS_OA" \
    && eval "$(sed -n '/^markers() {/,/^}/p' "$ORCH_OA")" && markers 42 )
}

# oa_gate_block_line <ERE> — one line of the bash block under "**Gate marker**" in agents/orchestrator.md, <N> -> 42
oa_gate_block_line() {
  awk '/^\*\*Gate marker\*\*/ {on=1; next} on && /^```bash/ {inb=1; next} on && inb && /^```/ {exit} on && inb {print}' "$ORCH_OA" \
    | grep -E "$1" | head -1 | sed 's/<N>/42/g'
}

# oa_gate — the REAL gate-marker command (the `banned=` and `markers <N> |` lines) fed by the REAL markers()
oa_gate() {
  local b m
  b=$(oa_gate_block_line '^banned='); m=$(oa_gate_block_line '^markers <N> ')
  [ -n "$b" ] && [ -n "$m" ] || { echo "NO-GATE-SNIPPET"; return 0; }
  ( cd "$OA_DIR/work" && PATH="$OA_DIR/bin:$PATH" && . "$MARKERS_OA" \
    && eval "$(sed -n '/^markers() {/,/^}/p' "$ORCH_OA")" && { eval "$b"; } 2>/dev/null; eval "$m" )
}

# oa_note_url — the REAL "latest auto-retry NOTE" command under "**Gate marker**" (gives the URL row 85 passes on)
oa_note_url() {
  local c; c=$(oa_gate_block_line 'autoretry_note_re')
  [ -n "$c" ] || { echo "NO-NOTE-COMMAND"; return 0; }
  ( cd "$OA_DIR/work" && PATH="$OA_DIR/bin:$PATH" && . "$MARKERS_OA" && eval "$c" )
}

# ------------------------------------------------------------------------------------------ cases

# The incident: BLOCKED ci_pending, then the supervisor's NOTE. The orchestrator's trail must end BLOCKED -> NOTE, the
# gate marker must stay the BLOCKED (so delegated-decision Resolves: checks keep working), and the NOTE URL is available.
test_oa_markers_surfaces_the_real_supervisor_note_after_the_blocked() {
  local note out last prev gate url rc=0
  note=$(oa_writer_note ci_pending)
  assert_contains "$note" "**[supervisor] NOTE** auto-retry 1/3: ci_pending cleared" "writer: real supervisor tick posted the NOTE" || return 1
  oa_setup; oa_thread "$note"
  out=$(oa_markers); last=$(printf '%s\n' "$out" | tail -1); prev=$(printf '%s\n' "$out" | tail -2 | head -1)
  gate=$(oa_gate | grep -v '^$' | tail -1); url=$(oa_note_url)
  oa_teardown
  assert_eq "$last" "2026-10-28T10:40:00Z jpmoya $note" "reader: markers() lists the supervisor's auto-retry NOTE as the newest line" || rc=1
  assert_eq "$prev" "2026-10-28T10:30:00Z jpmoya **[deployer] BLOCKED**" "reader: the BLOCKED it resumes is the line before it" || rc=1
  assert_not_contains "$out" "claim:" "reader: the claim NOTE stays filtered out" || rc=1
  assert_eq "$gate" "2026-10-28T10:30:00Z jpmoya **[deployer] BLOCKED**" "gate marker stays the BLOCKED (the NOTE resumes it, it is not a new state)" || rc=1
  assert_contains "$url" "https://github.com/o/r/issues/42#issuecomment-1040" "the auto-retry NOTE command prints the NOTE's URL for the re-dispatch prompt" || rc=1
  return $rc
}

# #473: when the supervisor tolerated infrastructure-only failures it appends ` — <detail>` to the same line. The old
# "first line is exactly ... cleared" rule rejected it even for a reader that could see it.
test_oa_markers_surfaces_the_note_with_the_infra_detail_suffix() {
  local note out rc=0
  note=$(oa_writer_note infra)
  assert_contains "$note" "auto-retry 1/3: ci_red cleared — only infrastructure-class checks fail" "writer: real supervisor tick posted the suffixed NOTE" || return 1
  oa_setup; oa_thread "$note"
  out=$(oa_markers)
  oa_teardown
  assert_eq "$(printf '%s\n' "$out" | tail -1)" "2026-10-28T10:40:00Z jpmoya $note" "reader: the suffixed NOTE is listed" || rc=1
  return $rc
}

# Every other NOTE stays inert: the widening is the auto-retry NOTE only, built from autoretry_classes.
test_oa_markers_keeps_every_other_note_out() {
  local out b rc=0
  oa_setup
  for b in '**[supervisor] NOTE** claim: vm 2026-10-28T10:40:00Z' \
           '**[deployer] NOTE** auto-retry 1/3: ci_pending cleared' \
           'see **[supervisor] NOTE** auto-retry 1/3: ci_pending cleared' \
           '**[supervisor] NOTE** auto-retry 1/3: needs_jp cleared' \
           '**[supervisor] NOTE** auto-retry 1/3: other cleared' \
           '**[supervisor] NOTE** auto-retry 1/3: ci_pending cleared?? not really' \
           '**[supervisor] NOTE** loop-cap hold resumed: a delegated decision was posted after the stop'; do
    oa_thread "$b"
    out=$(oa_markers)
    assert_eq "$(printf '%s\n' "$out" | tail -1)" "2026-10-28T10:30:00Z jpmoya **[deployer] BLOCKED**" "inert NOTE not listed: $b" || rc=1
  done
  oa_teardown
  return $rc
}

# A later BLOCKED supersedes the NOTE: it is the trail's last line and the gate marker.
test_oa_later_blocked_supersedes_the_note() {
  local note out gate rc=0
  note=$(autoretry_note_fixture)
  oa_setup; oa_thread "$note" $'**[deployer] BLOCKED**\nBlocked on: ci_red — unit-tests failing'
  out=$(oa_markers); gate=$(oa_gate | grep -v '^$' | tail -1)
  oa_teardown
  assert_eq "$(printf '%s\n' "$out" | tail -1)" "2026-10-28T10:50:00Z jpmoya **[deployer] BLOCKED**" "trail ends on the later BLOCKED" || rc=1
  assert_eq "$gate" "2026-10-28T10:50:00Z jpmoya **[deployer] BLOCKED**" "gate marker is the later BLOCKED" || rc=1
  return $rc
}
autoretry_note_fixture() { printf '%s' '**[supervisor] NOTE** auto-retry 1/3: ci_pending cleared'; }

# Install skew: ~/.claude/agents/orchestrator.md and ~/.claude/hooks/pipeline-markers.sh are copied separately, so the
# new markers() can run against a hook that has no autoretry_note_re. An empty regex matches every comment; markers()
# and the NOTE-URL command must fail closed (no output, markers non-zero) instead of listing the whole thread.
test_oa_markers_fails_closed_when_the_hook_predates_the_note_regex() {
  local out rc_m url rc=0
  oa_setup; oa_thread "$(autoretry_note_fixture)"
  out=$( cd "$OA_DIR/work" && PATH="$OA_DIR/bin:$PATH" && . "$MARKERS_OA" && unset -f autoretry_note_re \
    && eval "$(sed -n '/^markers() {/,/^}/p' "$ORCH_OA")" && markers 42 ); rc_m=$?
  url=$( cd "$OA_DIR/work" && PATH="$OA_DIR/bin:$PATH" && . "$MARKERS_OA" && unset -f autoretry_note_re \
    && eval "$(oa_gate_block_line 'autoretry_note_re')" 2>/dev/null )
  oa_teardown
  assert_ne "$rc_m" "0" "old hook: markers() reports a failed read" || rc=1
  assert_eq "$out" "" "old hook: markers() never lists every comment" || rc=1
  assert_eq "$url" "" "old hook: the NOTE-URL command never prints another comment's URL" || rc=1
  return $rc
}

# The widening is the orchestrator's read only: the shared routing vocabulary (marker_re) that the supervisor, the
# handoff hook and stage-run.sh read is unchanged, so the supervisor still sees the BLOCKED (and its class) as its gate
# and can post retries 2/3 and 3/3.
test_oa_supervisor_still_reads_the_blocked_class_behind_the_note() {
  local js cls rc=0
  js=$(jq -nc --arg b "$OA_BLOCKED" --arg n "$(autoretry_note_fixture)" \
    '{comments: [{body:$b, createdAt:"2026-10-28T10:30:00Z"}, {body:$n, createdAt:"2026-10-28T10:40:00Z"}]}')
  cls=$( . "$MARKERS_OA"; eval "$(awk '$0 ~ "^blocked_class_of\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SUP_OA")"; blocked_class_of "$js" )
  assert_eq "$cls" "ci_pending" "supervisor blocked_class_of still sees the ci_pending BLOCKED behind the NOTE" || rc=1
  ( . "$MARKERS_OA"; jq -ne --arg s "$(autoretry_note_fixture)" --arg re "$(marker_re)" '$s | test($re)' >/dev/null ) \
    && { fail "marker_re (shared routing vocabulary) must not match the auto-retry NOTE"; rc=1; }
  return $rc
}

run_test test_oa_markers_surfaces_the_real_supervisor_note_after_the_blocked
run_test test_oa_markers_surfaces_the_note_with_the_infra_detail_suffix
run_test test_oa_markers_keeps_every_other_note_out
run_test test_oa_later_blocked_supersedes_the_note
run_test test_oa_markers_fails_closed_when_the_hook_predates_the_note_regex
run_test test_oa_supervisor_still_reads_the_blocked_class_behind_the_note
