#!/bin/bash
# Shared pipeline defaults, sourced by orchestrate.sh and supervisor.sh.
# Per-machine overrides (DISPATCH_REPOS, caps) go in ~/.claude/pipeline/config.local.sh — untracked, no secrets here.

PIPE=/tmp/pipeline
QUEUE="$PIPE/queue"
LOGDIR="$HOME/logs/pipeline"

LABEL_PROPOSED="agent-proposed"     # hourly scan (VM) marks new issues
LABEL_GO="agent-go"                 # JP: launch this anywhere — consumed at launch
LABEL_IN_PROGRESS="agent-in-progress"  # an orchestrator owns this issue on some machine; removed when terminal/held

MAX_CONCURRENT=3
MEM_FLOOR_MB=1200
MAX_NO_PROGRESS=3
MAX_TOTAL=6
BACKOFF=(120 300 900 1800)
MIN_RUN_SECS=180                            # shorter runs are transient (rate limit, OOM, API error)
MAX_TRANSIENT_TOTAL=20
TRANSIENT_BACKOFF=(300 600 1200 1800 3600)
GRACE_PERIOD_SECS=1200                      # BLOCKED younger than this may be a subagent race — wait

# Shared dispatch: "owner/repo:/local/checkout" entries. Empty = this machine never dispatches from labels.
DISPATCH_REPOS=()
CLAIM_SETTLE_SECS=15       # wait after posting a claim before checking who was first
CLAIM_WINDOW_SECS=600      # claims older than this are ignored

[ -f "$HOME/.claude/pipeline/config.local.sh" ] && source "$HOME/.claude/pipeline/config.local.sh"

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
