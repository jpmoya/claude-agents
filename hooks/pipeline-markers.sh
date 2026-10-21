#!/bin/bash
# Routing-marker vocabulary for the agent pipeline — the single source of truth. Sourced by
# require-handoff-marker.sh, skills/orchestrate/supervisor.sh and the orchestrator's markers()/count().
# A comment is a routing marker only when line 1 is `**[agent] <one of these>` followed by `**`, `:`,
# a space or end of line. Anything else — NOTE, the literal word MARKER, an invented COMPLETED — is
# inert: it never changes pipeline state and never satisfies the handoff hook (claude-agents#5).
# SKIP MOCKUPS (#272) is honoured only from the issue author with a `JP said:` line 2 (see marker_last_jq).
# Adding a marker to an agent definition or the routing table means adding it here too.

markers_for() {  # markers_for <agent> → that agent's routing markers, |-separated (empty = unknown agent)
  case "$1" in
    product-manager)     echo 'READY FOR ARCHITECTURE|READY FOR ENGINEERING|EFFORT APPROVAL NEEDED|BLOCKED|REJECTED' ;;
    ux-flow-designer)    echo 'USER FLOW READY|NO UX NEEDED|NEEDS PM REVISION|BLOCKED' ;;
    ui-ux-designer)      echo 'MOCKUPS PENDING APPROVAL|BLOCKED' ;;
    solutions-architect) echo 'READY FOR ENGINEERING|NEEDS PM REVISION|SPEC RESOLVED|SPLIT|BLOCKED' ;;
    test-writer)         echo 'TESTS WRITTEN|TEST UPHELD|BLOCKED' ;;
    test-reviewer)       echo 'TESTS APPROVED|TESTS FAIL|PASS|FAIL|BLOCKED' ;;
    fullstack-developer) echo 'IMPLEMENTED|TEST DEFECT|BLOCKED|REJECTED' ;;
    code-reviewer)       echo 'PASS|FAIL|BLOCKED' ;;
    deployer)            echo 'DEPLOYED TO STAGING|DEPLOYED|BLOCKED' ;;   # 'DEPLOYED TO STAGING' = the deployer's staging phrasing, same terminal state (2026-09-22)
    infra-planner)       echo 'PLAN READY|BLOCKED' ;;
    infra-reviewer)      echo 'PLAN PASS|PLAN FAIL|BLOCKED' ;;
    infra-operator)      echo 'APPLIED|AWAITING GO|BLOCKED' ;;
    intake)              echo 'TRIAGED BUG|TRIAGED IDEA|DUPLICATE|NEEDS INFO|NOISE|BLOCKED' ;;   # raw-feedback triage, launched by the supervisor, never by the orchestrator (#114)
    orchestrator)        echo 'BLOCKED' ;;   # config-error refusal: parks the run through the gate path instead of a silent exit (#75)
    jp)                  echo 'GO|MOCKUPS APPROVED|SKIP MOCKUPS' ;;
    delivery-lead)       echo 'DECISION|JP CONFIRMED' ;;  # JP's delegate (legacy spelling below, #192): same markers, same limits
    project-manager)     echo 'DECISION|JP CONFIRMED' ;;  # JP's delegate: resumes a code-track BLOCKED and the two caps only — never jp's gates (claude-agents#59)
  esac
}

jp_approval_re() {  # regex over a FULL comment body, must compile under both gh's --jq (gojq / Go RE2, no lookaround) and system jq (oniguruma): JP's approval — the ONE word set (#310, widened 2026-10-18 by JP's direct instruction: a real approval of his ("Approved — proceed.") kept failing over the exact punctuation character used, and he never wants that class of miss again). Callers must also check the author (identity is the anti-forgery) and the date.
  # Case-insensitive. Matches when the first non-empty line is a word phrase optionally followed by a separator and free text,
  # or when any line is only a phrase plus optional trailing punctuation / whitespace / CR. A phrase inside a sentence never matches.
  # The separator is deliberately "any run of characters that are neither letters/digits nor whitespace" rather than a
  # hand-picked punctuation list: a plain hyphen, an en dash, an em dash, a colon, an arrow, a bullet, two typos in a
  # row — anything — all count, so no future punctuation character can silently break a real approval the way the
  # em dash did here. The only thing this never accepts is the word glued directly to more letters/digits with
  # nothing between (e.g. "go ahead", "disapproved", "gone") — that is what keeps it from firing on ordinary sentences.
  local words legacy sep
  words='approved|approve|go|proceed|lgtm|ok to proceed'
  sep='[^A-Za-z0-9\s]+'
  legacy="\\*\\*\\[jp\\] ($(markers_for jp))\\*\\*"   # the legacy marker forms, from markers_for jp
  printf '%s' "(?i)(?:\\A\\s*(?:$words)\\s*(?:$sep)\\s*\\S|(?:\\A|\\n)\\s*(?:$words|$legacy)[.!,;:]*\\s*(?:\\n|\\z))"
}

is_jp_approval() {  # is_jp_approval <body> → exit 0 when the body is an approval phrase (word set only; author/date are the caller's checks)
  jq -ne --arg b "$1" --arg re "$(jp_approval_re)" '$b | test($re)' >/dev/null
}

marker_re() {  # marker_re [agent] → jq (oniguruma) regex for a valid first line; no agent = any agent, each with its own markers
  # jp's markers are gates: the first line must be the marker and nothing else (trailing whitespace/CR ok),
  # the same "exactly" rule the orchestrator applies (#202). Other agents keep the `**`/`:`/space/EOL suffix.
  local a alt="" jpalt
  jpalt="jp\\] ($(markers_for jp))\\*\\*[[:space:]]*\$"
  if [ "${1:-}" = jp ]; then
    jp_approval_re; return   # #310: jp's gates take the shared approval-word set, not only the legacy exact line
  fi
  if [ -n "${1:-}" ]; then
    alt=$(markers_for "$1"); [ -n "$alt" ] || alt='BLOCKED'
    alt="$1\\] ($alt)"
  else
    # literal list, not a variable: zsh (the Mac Bash tool's shell) does not word-split unquoted variables
    for a in product-manager ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer fullstack-developer code-reviewer deployer \
             infra-planner infra-reviewer infra-operator delivery-lead project-manager intake orchestrator; do alt="${alt:+$alt|}$a\\] ($(markers_for "$a"))"; done
    printf '^\\*\\*\\[((%s)(\\*\\*|:| |$)|%s)' "$alt" "$jpalt"; return
  fi
  printf '^\\*\\*\\[(%s)(\\*\\*|:| |$)' "$alt"
}

block_classes() { echo 'ci_pending|ci_red|merge_conflict|unsupported_project|needs_jp|dependency|cost_ceiling|other'; }  # class word on a BLOCKED comment's `Blocked on:` line (line 2); anything else reads as `other`
parkable_classes() { echo 'ci_pending|ci_red|merge_conflict|unsupported_project|dependency|other'; }  # #250: BLOCKED classes that are not JP-only (parked, shown with a reason)
autoretry_classes() { echo 'ci_pending|ci_red|merge_conflict|dependency'; }  # #250: the subset the supervisor re-checks and relaunches once cleared
