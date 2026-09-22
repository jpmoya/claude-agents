#!/bin/bash
# Routing-marker vocabulary for the agent pipeline — the single source of truth. Sourced by
# require-handoff-marker.sh, skills/orchestrate/supervisor.sh and the orchestrator's markers()/count().
# A comment is a routing marker only when line 1 is `**[agent] <one of these>` followed by `**`, `:`,
# a space or end of line. Anything else — NOTE, the literal word MARKER, an invented COMPLETED — is
# inert: it never changes pipeline state and never satisfies the handoff hook (claude-agents#5).
# Adding a marker to an agent definition or the routing table means adding it here too.

markers_for() {  # markers_for <agent> → that agent's routing markers, |-separated (empty = unknown agent)
  case "$1" in
    product-manager)     echo 'READY FOR ARCHITECTURE|READY FOR ENGINEERING|EFFORT APPROVAL NEEDED|BLOCKED' ;;
    ux-flow-designer)    echo 'USER FLOW READY|NO UX NEEDED|NEEDS PM REVISION|BLOCKED' ;;
    ui-ux-designer)      echo 'MOCKUPS PENDING APPROVAL|BLOCKED' ;;
    solutions-architect) echo 'READY FOR ENGINEERING|NEEDS PM REVISION|SPEC RESOLVED|SPLIT|BLOCKED' ;;
    test-writer)         echo 'TESTS WRITTEN|TEST UPHELD|BLOCKED' ;;
    test-reviewer)       echo 'TESTS APPROVED|TESTS FAIL|PASS|FAIL|BLOCKED' ;;
    fullstack-developer) echo 'IMPLEMENTED|TEST DEFECT|BLOCKED' ;;
    code-reviewer)       echo 'PASS|FAIL|BLOCKED' ;;
    deployer)            echo 'DEPLOYED TO STAGING|DEPLOYED|BLOCKED' ;;   # 'DEPLOYED TO STAGING' = the deployer's staging phrasing, same terminal state (2026-09-22)
    infra-planner)       echo 'PLAN READY|BLOCKED' ;;
    infra-reviewer)      echo 'PLAN PASS|PLAN FAIL|BLOCKED' ;;
    infra-operator)      echo 'APPLIED|AWAITING GO|BLOCKED' ;;
    jp)                  echo 'GO|MOCKUPS APPROVED' ;;
    project-manager)     echo 'DECISION|JP CONFIRMED' ;;  # JP's delegate: resumes a code-track BLOCKED and the two caps only — never jp's gates (claude-agents#59)
  esac
}

marker_re() {  # marker_re [agent] → jq (oniguruma) regex for a valid first line; no agent = any agent, each with its own markers
  local a alt=""
  if [ -n "${1:-}" ]; then
    alt=$(markers_for "$1"); [ -n "$alt" ] || alt='BLOCKED'
    alt="$1\\] ($alt)"
  else
    # literal list, not a variable: zsh (the Mac Bash tool's shell) does not word-split unquoted variables
    for a in product-manager ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer fullstack-developer code-reviewer deployer \
             infra-planner infra-reviewer infra-operator jp project-manager; do alt="${alt:+$alt|}$a\\] ($(markers_for "$a"))"; done
  fi
  printf '^\\*\\*\\[(%s)(\\*\\*|:| |$)' "$alt"
}
