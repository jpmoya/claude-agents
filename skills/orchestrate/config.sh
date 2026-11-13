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
LABEL_SENTRY_GO="sentry-auto-go"    # a Sentry bug released automatically (SENTRY_AUTO_GO=1) — counted against SENTRY_AUTO_GO_DAILY_CAP (#182); never on a hand-released ticket

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
JP_GATE_REMIND_SECS=86400                   # a run parked "waiting on JP" this long gets one #engineering reminder per hold (#677)

# Intake agent (#114): 1 = a triaged bug gets agent-go directly (default since #115); 0 = bug gets agent-proposed instead
INTAKE_AUTO_GO=1
# Intake / spec retry (#676): a run that exits with no handoff marker is classified. A usage-limit exit never counts and never
# gives up (nothing is launched by steps 3b/3c until the stamp passes: this long for a monthly spend limit, RATE_LIMIT_BACKOFF_SECS
# otherwise); a transient exit (non-zero or no exit code) is released without counting, up to INTAKE_MAX_TRANSIENT per cycle,
# after the next TRANSIENT_BACKOFF wait; a give-up expires after INTAKE_GAVEUP_RETRY_SECS, INTAKE_MAX_GIVEUPS cycles in total.
INTAKE_LIMIT_BACKOFF_SPEND_SECS=21600
INTAKE_MAX_TRANSIENT=3
INTAKE_GAVEUP_RETRY_SECS=21600
INTAKE_MAX_GIVEUPS=4
# Sentry-sourced bugs (#176): never follow INTAKE_AUTO_GO. 1 = a triaged Sentry bug goes straight to the fix pipeline
# (agent-go; the default since #678); 0 = agent-proposed for JP (his digest). The supervisor, not the intake agent, sets the
# labels of a Sentry ticket (intake_apply_decision writes them, sentry_label_gate enforces them from the handoff marker).
# Kill switch: SENTRY_AUTO_GO=0 in ~/.claude/pipeline/config.local.sh. Worst-case spend per app per day =
# SENTRY_AUTO_GO_DAILY_CAP x COST_CEILING_USD (below).
SENTRY_AUTO_GO=1
# Daily launch cap for automatically released Sentry tickets (#182). With SENTRY_AUTO_GO=1 the label helper adds
# LABEL_SENTRY_GO next to agent-go; at most this many tickets carrying it are launched per repo in any rolling 24 h
# (orchestrate.sh refuses with exit 3, supervisor step 5 leaves the ticket queued). Worst-case spend = cap x
# COST_CEILING_USD per app per day: 3 x $40 = $120. The count is this host's own $PIPE/sentry-launches.log (no GitHub
# call), so two dispatching hosts each allow the cap. 0 = no automatic Sentry launch. A ticket JP releases by hand (after
# intake is done) never carries the label and is never throttled; SENTRY_CAP_BYPASS=1 in the environment lets one hand
# launch through. The cap bounds new tickets: an automatic restart or queue drain of a ticket that already launched is not
# counted again (COST_CEILING_USD bounds what one ticket can spend across its restarts).
SENTRY_AUTO_GO_DAILY_CAP=3

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

# #645: the test harness's hard-disable of #643's CI queue collector must survive a real host
# config.local.sh (sourced just above) turning it back on — run-tests.sh exports
# CI_QUEUE_COLLECT_TEST_DISABLE=1 (a marker config.local.sh has no reason to ever set) and nothing
# sourced after this line can re-enable report-status.sh's gh/GitHub API calls. Set AFTER the host
# override, same pattern as DIRECT_ROUTE_REPOS below.
[ "${CI_QUEUE_COLLECT_TEST_DISABLE:-0}" != "1" ] || CI_QUEUE_COLLECT_ENABLED=0

# Direct-route repos (#632): the pipeline never runs them — orchestrate.sh refuses the launch (exit 2, no --force), the
# supervisor and the goal machinery ignore their tickets. Set AFTER the host override so no config.local.sh can clear it.
# Changed only by an interactive session with subagents — never orchestrate.sh, agent-go, a goal or the supervisor (#632).
DIRECT_ROUTE_REPOS=("jpmoya/claude-agents")
# direct_route_repo <owner/repo[:path]> -> 0 when the repo is in DIRECT_ROUTE_REPOS, 1 otherwise. Case-insensitive (GitHub
# owner/repo is); only the part before the first ":" is compared, so a DISPATCH_REPOS-shaped "owner/repo:/path" entry works.
direct_route_repo() {
  local want=$1 e
  want=$(printf '%s' "${want%%:*}" | tr '[:upper:]' '[:lower:]')
  [ -n "$want" ] || return 1
  for e in ${DIRECT_ROUTE_REPOS[@]+"${DIRECT_ROUTE_REPOS[@]}"}; do
    [ "$(printf '%s' "${e%%:*}" | tr '[:upper:]' '[:lower:]')" = "$want" ] && return 0
  done
  return 1
}
# direct_route_drop <array name> — rebuilds that repo list in the current shell without its direct-route entries. Each drop is
# appended to DIRECT_ROUTE_DROPPED as "<array name> <owner/repo>" (one per line) so the supervisor can log it: a re-added
# config.local.sh entry is harmless, every consumer of the lists (dispatch, intake, spec, sweep, reconcile, scan, goals) sees
# the filtered arrays.
DIRECT_ROUTE_DROPPED=""
direct_route_drop() {
  local _n=$1 _e; local -a _kept=()
  eval "set -- \${$_n[@]+\"\${$_n[@]}\"}"
  for _e in "$@"; do
    if direct_route_repo "$_e"; then DIRECT_ROUTE_DROPPED="$DIRECT_ROUTE_DROPPED$_n ${_e%%:*}"$'\n'; else _kept+=("$_e"); fi
  done
  eval "$_n=(\${_kept[@]+\"\${_kept[@]}\"})"
}
for _n in DISPATCH_REPOS SCAN_ONLY_REPOS; do direct_route_drop "$_n"; done; unset _n

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

# GitHub API budget guard (gh-budget.sh): call log, quota tiers, short read cache. Thresholds are REST/GraphQL "remaining" calls.
GH_QUOTA_OPTIONAL_BELOW="${GH_QUOTA_OPTIONAL_BELOW:-1500}"   # below this, optional work (status push, stale digest, scan-backlog, held-goal evaluation, worktree sweep, status reconcile) is skipped
GH_QUOTA_ESSENTIAL_BELOW="${GH_QUOTA_ESSENTIAL_BELOW:-300}"  # below this, only essential work (restarting live runs, draining already-queued launches) runs; 0 = no gh call until the reset
GH_QUOTA_TTL_SECS="${GH_QUOTA_TTL_SECS:-60}"                 # `gh api rate_limit` is read at most this often (cached in $PIPE/gh-quota)
GH_CACHE_TTL_SECS="${GH_CACHE_TTL_SECS:-60}"                 # milestone/label/registry reads are reused this long (0 = off); a single issue/its comments has no TTL, see #637; all flushed by any write
if [ -f "$(dirname "${BASH_SOURCE[0]}")/gh-budget.sh" ]; then . "$(dirname "${BASH_SOURCE[0]}")/gh-budget.sh"
else   # config.sh copied without its siblings (a test fixture): the budget guard is simply absent
  GH_BUDGET_ENABLED=0; gh_class() { :; }; gh_tier_allows() { return 0; }; gh_tick_due() { return 0; }; gh_cache_clear() { :; }; gh_since_sync() { return 0; }
fi
