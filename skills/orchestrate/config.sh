#!/bin/bash
# Shared pipeline defaults, sourced by orchestrate.sh and supervisor.sh.
# Per-machine overrides (DISPATCH_REPOS, caps) go in ~/.claude/pipeline/config.local.sh — untracked, no secrets here.

PIPE="${PIPE:-/tmp/pipeline}"
QUEUE="${QUEUE:-$PIPE/queue}"
LOGDIR="${LOGDIR:-$HOME/logs/pipeline}"

LABEL_PROPOSED="agent-proposed"     # hourly scan (VM) marks new issues
LABEL_GO="agent-go"                 # JP: launch this anywhere — consumed at launch
LABEL_IN_PROGRESS="agent-in-progress"  # an orchestrator owns this issue on some machine; removed when terminal/held
LABEL_FEEDBACK="user-feedback"      # a bug/idea that started as staff feedback — always auto-dispatched, even when SHARED_DISPATCH_ENABLED=0 (JP 2026-10-19)

MAX_CONCURRENT=3
MAX_CLAUDE_PROCS=10                         # orchestrator pre-dispatch gate ceiling: counts pipeline-launched claude processes (orchestrators, their stages, delivery-lead goal runs and supervisor-launched intake/product-manager runs, minus the caller; a rough bound). must stay ≥ 3 × (1 + 2 stages) − 1 + MAX_GOALS — raise it whenever MAX_CONCURRENT or MAX_GOALS is raised.
MEM_FLOOR_MB=1200
MAX_NO_PROGRESS=3
MAX_TOTAL=6
BACKOFF=(120 300 900 1800)
MIN_RUN_SECS=180                            # shorter runs are transient (rate limit, OOM, API error)
TRANSIENT_BACKOFF=(300 600 1200 1800 3600)
RATE_LIMIT_BACKOFF_SECS=3600                # weekly/unrecognised usage limit: wait this long before the restart, not counted toward stalled
GRACE_PERIOD_SECS=1200                      # BLOCKED younger than this may be a subagent race — wait

# Intake agent (#114): 1 = a triaged bug gets agent-go directly (default since #115); 0 = bug gets agent-proposed instead
INTAKE_AUTO_GO=1
# Sentry-sourced bugs (#176): never follow INTAKE_AUTO_GO. 0 = agent-proposed (JP's digest); 1 = agent-go directly.
SENTRY_AUTO_GO=0

# Shared dispatch: "owner/repo:/local/checkout" entries. Empty = this machine never dispatches from labels.
DISPATCH_REPOS=()
# JP (2026-10-18): only the goal-based pipeline (deliver.sh / delivery-lead) should launch work; a bare agent-go
# ticket with no goal must not auto-run. 0 = supervisor step 5 (shared dispatch) never claims or launches a ticket,
# whatever DISPATCH_REPOS says; a goal's own dispatch (goal_launch, the delivery lead's hand-launches) is unaffected.
# A hand launch (orchestrate.sh <repo> <issue>, run by JP or an agent he points at it) still works either way.
SHARED_DISPATCH_ENABLED=${SHARED_DISPATCH_ENABLED:-1}
# Scanned by scan-backlog.sh, never dispatched. "owner/repo" entries; a ":path" suffix is tolerated and ignored.
SCAN_ONLY_REPOS=()
CLAIM_SETTLE_SECS=${PIPELINE_TEST_CLAIM_SETTLE_SECS:-15}  # (test-only override) wait after posting a claim before checking who was first
CLAIM_WINDOW_SECS=600      # claims older than this are ignored

# Log rotation (rotate-logs.sh, issue #141) and the per-ticket cost ceiling (stage-run.sh)
ROTATE_MIN_BYTES=1048576   # rotate supervisor.log / report-status.log / runs.jsonl when larger than this
ROTATE_KEEP=12             # rotations kept per log
RUNS_KEEP_DAYS=14          # runs.jsonl lines newer than this stay in the live file
COST_CEILING_USD=40        # refuse a new fix-cycle developer/test-writer stage once a ticket's logged cost passes this; 0 = off

# Goal-bound delivery lead (#193): the agent deliver.sh launches (claude-agents#192 flips the default) and the repo that
# hosts the goal registry issues (label delivery-goal) — one registry for every goal, whatever repo the goal is on.
GOAL_AGENT=project-manager   # deprecated alias of delivery-lead (#192); default flip is a follow-up, goal tests pin this value
GOAL_REGISTRY_REPO=jpmoya/claude-agents
# Supervisor goal step (#195)
MAX_GOALS=2                 # goal (delivery-lead) pids alive at once on this host; not counted in count_running
GOAL_CYCLE_SECS=1200        # a cleanly ended cycle is relaunched only this long after its launch
GOAL_SYNC_SECS=300          # registry sync + live-goal re-evaluation throttle, per host
GOAL_MAX_NO_PROGRESS=3      # relaunch decisions with an unchanged scope snapshot before a goal is parked

[ -f "$HOME/.claude/pipeline/config.local.sh" ] && source "$HOME/.claude/pipeline/config.local.sh"

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
