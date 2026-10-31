#!/bin/bash
# Shared pipeline defaults, sourced by orchestrate.sh and supervisor.sh.
# Per-machine overrides (DISPATCH_REPOS, caps) go in ~/.claude/pipeline/config.local.sh — untracked, no secrets here.

# Run state is durable (#332): /tmp is emptied by a reboot, which orphaned in-flight runs (2026-10-16). Same default in stage-run.sh,
# hooks/require-handoff-marker.sh and install.sh. PIPE_DEFAULTED gates the one-time move below (an explicit PIPE is never moved).
PIPE_DEFAULTED=0; [ -n "${PIPE:-}" ] || PIPE_DEFAULTED=1
PIPE="${PIPE:-$HOME/.claude/pipeline/state}"
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
MAX_GOALS=2                 # goal (delivery-lead) pids alive at once on this host; not counted in count_running (with GOAL_SERIAL=1 the one goal plus any feedback goals)
GOAL_CYCLE_SECS=1200        # a cleanly ended cycle is relaunched only this long after its launch
GOAL_SYNC_SECS=300          # registry sync + live-goal re-evaluation throttle, per host
GOAL_MAX_NO_PROGRESS=3      # relaunch decisions with an unchanged scope snapshot before a goal is parked
GOAL_MAX_LAUNCH_FAILS=3     # consecutive attempts that never got to work (launch error / exit < MIN_RUN_SECS) before a goal is parked (#514)
# One goal at a time (JP 2026-10-30): 1 = a single goal slot for BOTH hosts. A queued goal starts only when no other goal is
# active anywhere (registry state), a goal coming back from held / waiting on JP goes back to the queue instead of
# relaunching, an extra active goal (a --now / resume hand launch, or a goal already running when this was switched on)
# finishes its current cycle and then returns to the queue, and the other host dispatches the one active goal's agent-go
# tickets even with SHARED_DISPATCH_ENABLED=0. 0 = the old behaviour: up to MAX_GOALS leads per host, no cross-host spread
# while shared dispatch is off. Revert = set 0 here and sync both hosts (a per-host override splits the guarantee).
GOAL_SERIAL=${GOAL_SERIAL:-1}
# 0 = a running standing feedback goal (owner/repo:feedback) never holds the slot (it starts in its queue turn, then runs
# beside the one goal and is never sent back to the queue); 1 = feedback goals take the slot like any goal.
GOAL_SERIAL_FEEDBACK=${GOAL_SERIAL_FEEDBACK:-0}

# Supervisor stale-work digest (#491): pure observability, logged/alerted, never acted on automatically.
STALE_WORK_HOURS=4

[ -f "$HOME/.claude/pipeline/config.local.sh" ] && source "$HOME/.claude/pipeline/config.local.sh"

# #332: one-time move of the old /tmp run state to the durable path (only when the new path is absent), leaving a symlink so
# processes started before the move, and agent docs that still name /tmp/pipeline, keep writing to the same place.
# PIPE_LEGACY is pinned away from the real /tmp/pipeline by tests/run-tests.sh (#341).
if [ "$PIPE_DEFAULTED" = 1 ] && [ "$PIPE" = "$HOME/.claude/pipeline/state" ]; then
  PIPE_LEGACY="${PIPE_LEGACY:-/tmp/pipeline}"
  if [ ! -e "$PIPE" ] && [ -d "$PIPE_LEGACY" ] && [ ! -L "$PIPE_LEGACY" ]; then
    mkdir -p "$(dirname "$PIPE")" && mv "$PIPE_LEGACY" "$PIPE" && ln -s "$PIPE" "$PIPE_LEGACY"
  fi
fi
# #332: pids stored before the last reboot may now belong to unrelated processes, so the supervisor's `kill -0` alive test
# could call a dead run alive forever. On the first config.sh load after a boot, overwrite every stored pid with one that
# cannot exist; the existing dead-process restart path then relaunches the run (state itself survived).
if [ -d "$PIPE" ]; then
  _boot="${PIPELINE_BOOT_EPOCH:-}"
  if [ -z "$_boot" ]; then
    if [ -r /proc/stat ]; then _boot=$(awk '/^btime/ {print $2}' /proc/stat) || _boot=
    else _boot=$( { /usr/sbin/sysctl -n kern.boottime || sysctl -n kern.boottime; } 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\).*/\1/p') || _boot=; fi
  fi
  case "$_boot" in ''|*[!0-9]*) ;; *)
    _prev=$(cat "$PIPE/.boot-epoch" 2>/dev/null) || _prev=
    if [ "$_prev" != "$_boot" ]; then
      # no stamp yet = first deploy of this change: live runs are still alive, only record the boot
      if [ -n "$_prev" ]; then for _pf in "$PIPE"/*.pid; do [ -f "$_pf" ] && echo 2147483646 > "$_pf"; done; fi
      echo "$_boot" > "$PIPE/.boot-epoch"
    fi ;;
  esac
  unset _boot _pf _prev
fi

# Prepend the tool dirs, but keep any that the caller already put on PATH where it put them: tests (and
# operators) shadow claude/gh with stubs by putting a dir first, and an unconditional prepend let the real
# /usr/local/bin/claude or /opt/homebrew/bin/claude win over the stub on a Mac (68 test failures on main).
_pp=""
for _d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin /opt/homebrew/bin; do
  case ":$PATH:" in *":$_d:"*) ;; *) _pp="$_pp$_d:" ;; esac
done
export PATH="$_pp$PATH"; unset _pp _d
# Node pin (docs/host-sync.md): headless agents run the pinned major on every host (CI uses 22). Homebrew's keg-only node@22
# is preferred when present; the VM's system node is already 22. bin/host-drift.py alerts if the pipeline PATH resolves another major.
PIPELINE_NODE_MAJOR="${PIPELINE_NODE_MAJOR:-22}"
for _nd in "/opt/homebrew/opt/node@$PIPELINE_NODE_MAJOR/bin" "/usr/local/opt/node@$PIPELINE_NODE_MAJOR/bin"; do
  [ -x "$_nd/node" ] && { export PATH="$_nd:$PATH"; break; }
done
unset _nd
